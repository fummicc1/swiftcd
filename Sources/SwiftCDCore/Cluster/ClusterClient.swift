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
    /// namespace内で `swiftcd.io/app=<appName>` ラベルが付いた全リソース
    func managedObjects(appName: String, namespace: String) async throws -> [LiveObject]
    func delete(_ objects: [LiveObject], namespace: String) async throws -> String
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
        // 空のListを渡すとkubectlは "no objects passed" で失敗する。全部Gitから消した場合もpruneできるようにする。
        guard !manifests.resources.isEmpty else {
            return DiffResult(outOfSync: [], hasDiff: false)
        }
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
        guard !manifests.resources.isEmpty else {
            return ""
        }
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

    /// ラベルがコピーされるだけの種類。取得しても除外するので、最初から問い合わせない。
    static let skippedResourceTypes: Set<String> = [
        "endpoints", "endpointslices.discovery.k8s.io", "events", "events.events.k8s.io",
    ]

    public func managedObjects(appName: String, namespace: String) async throws -> [LiveObject] {
        let types = try await runner.runChecked(kubectl([
            "api-resources", "--verbs=list,delete", "--namespaced=true", "-o", "name",
        ])).stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !Self.skippedResourceTypes.contains($0) }
        guard !types.isEmpty else {
            return []
        }
        let result = try await runner.runChecked(kubectl([
            "get", types.joined(separator: ","), "-n", namespace,
            "-l", "\(ManifestRenderer.appLabel)=\(appName)", "-o", "json",
        ]))
        return try Self.parseLiveObjects(Data(result.stdout.utf8))
    }

    public func delete(_ objects: [LiveObject], namespace: String) async throws -> String {
        guard !objects.isEmpty else {
            return ""
        }
        // ライブのオブジェクトをそのまま渡すと余計なフィールドまで含むので、特定に必要な項目だけに絞る。
        let items: [[String: Any]] = objects.compactMap { object in
            guard let json = try? JSONSerialization.jsonObject(with: object.json) as? [String: Any],
                  let metadata = json["metadata"] as? [String: Any] else {
                return nil
            }
            return [
                "apiVersion": json["apiVersion"] ?? "",
                "kind": json["kind"] ?? "",
                "metadata": ["name": metadata["name"] ?? "", "namespace": namespace],
            ]
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swiftcd-prune-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["apiVersion": "v1", "kind": "List", "items": items]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await runner.runChecked(kubectl([
            "delete", "-n", namespace, "-f", file.path, "--ignore-not-found",
        ]))
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
