import Foundation

public struct DiffResult: Sendable, Equatable {
    public var outOfSync: Set<ResourceRef>
    public var hasDiff: Bool

    public init(outOfSync: Set<ResourceRef>, hasDiff: Bool) {
        self.outOfSync = outOfSync
        self.hasDiff = hasDiff
    }
}

public struct LiveObject: Sendable, Equatable {
    public var ref: ResourceRef
    /// クラスタから取得したオブジェクトのJSON
    public var json: Data

    public init(ref: ResourceRef, json: Data) {
        self.ref = ref
        self.json = json
    }
}

public protocol ClusterClient: Sendable {
    func namespaceExists(_ namespace: String) async throws -> Bool
    func ensureNamespace(_ namespace: String) async throws
    func diff(_ manifests: RenderedManifests, namespace: String) async throws -> DiffResult
    func apply(_ manifests: RenderedManifests, namespace: String) async throws -> String
    func liveObjects(_ manifests: RenderedManifests, namespace: String) async throws -> [LiveObject]
}

public struct KubectlClient: ClusterClient {
    public static let fieldManager = "swiftcd"

    private let runner: CommandRunner
    private let context: String?

    public init(runner: CommandRunner = ProcessRunner(), context: String? = nil) {
        self.runner = runner
        self.context = context
    }

    private func kubectl(_ args: [String]) -> [String] {
        ["kubectl"] + (context.map { ["--context", $0] } ?? []) + args
    }

    public func namespaceExists(_ namespace: String) async throws -> Bool {
        let result = try await runner.run(kubectl(["get", "namespace", namespace, "--ignore-not-found", "-o", "name"]), in: nil)
        guard result.exitCode == 0 else {
            throw CommandError(command: ["kubectl", "get", "namespace", namespace], result: result)
        }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func ensureNamespace(_ namespace: String) async throws {
        if try await namespaceExists(namespace) {
            return
        }
        try await runner.runChecked(kubectl(["create", "namespace", namespace]))
    }

    public func diff(_ manifests: RenderedManifests, namespace: String) async throws -> DiffResult {
        let args = kubectl([
            "diff", "--server-side", "--force-conflicts", "--field-manager=\(Self.fieldManager)",
            "-n", namespace, "-f", manifests.file.path,
        ])
        let result = try await runner.run(args, in: nil)
        switch result.exitCode {
        case 0:
            return DiffResult(outOfSync: [], hasDiff: false)
        case 1:
            let refs = Self.parseDiffTargets(result.stdout, candidates: manifests.resources)
            return DiffResult(outOfSync: refs.isEmpty ? Set(manifests.resources) : refs, hasDiff: true)
        default:
            throw CommandError(command: args, result: result)
        }
    }

    /// `kubectl diff` は `diff -u -N /tmp/LIVE-x/apps.v1.Deployment.<ns>.<name> /tmp/MERGED-x/...`
    /// という行を出力するので、そのファイル名から差分のあるリソースを特定する。
    static func parseDiffTargets(_ output: String, candidates: [ResourceRef]) -> Set<ResourceRef> {
        let targets = output.split(separator: "\n")
            .filter { $0.hasPrefix("diff ") }
            .compactMap { $0.split(separator: " ").last.map { String($0.split(separator: "/").last ?? "") } }

        var result = Set<ResourceRef>()
        for ref in candidates {
            let groupPrefix = ref.group.isEmpty ? "" : "\(ref.group)."
            if targets.contains(where: { $0.hasPrefix(groupPrefix) && $0.contains(".\(ref.kind).") && $0.hasSuffix(".\(ref.name)") }) {
                result.insert(ref)
            }
        }
        return result
    }

    public func apply(_ manifests: RenderedManifests, namespace: String) async throws -> String {
        let result = try await runner.runChecked(kubectl([
            "apply", "--server-side", "--force-conflicts", "--field-manager=\(Self.fieldManager)",
            "-n", namespace, "-f", manifests.file.path,
        ]))
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func liveObjects(_ manifests: RenderedManifests, namespace: String) async throws -> [LiveObject] {
        guard !manifests.resources.isEmpty else {
            return []
        }
        let result = try await runner.runChecked(kubectl([
            "get", "-n", namespace, "-f", manifests.file.path, "--ignore-not-found", "-o", "json",
        ]))
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }
        return try Self.parseLiveObjects(Data(text.utf8))
    }

    static func parseLiveObjects(_ data: Data) throws -> [LiveObject] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // 1件のときは単体オブジェクト、複数のときは `kind: List` で返ってくる。
        let items = (root["kind"] as? String == "List") ? (root["items"] as? [[String: Any]] ?? []) : [root]
        return try items.compactMap { item in
            guard let apiVersion = item["apiVersion"] as? String,
                  let kind = item["kind"] as? String,
                  let name = (item["metadata"] as? [String: Any])?["name"] as? String else {
                return nil
            }
            return LiveObject(
                ref: ResourceRef(apiVersion: apiVersion, kind: kind, name: name),
                json: try JSONSerialization.data(withJSONObject: item))
        }
    }
}
