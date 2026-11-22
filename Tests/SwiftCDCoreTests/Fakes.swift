import Foundation
@testable import SwiftCDCore

/// checkoutのたびに、現在の `files` をclone先へ書き出すGit。
final class FakeGit: GitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private var sha: String

    init(files: [String: String], sha: String = "aaaaaaa") {
        self.files = files
        self.sha = sha
    }

    func commit(files: [String: String], sha: String) {
        lock.withLock {
            self.files = files
            self.sha = sha
        }
    }

    func checkout(repoURL: String, revision: String, into directory: URL) async throws -> GitRevision {
        let (files, sha) = lock.withLock { (self.files, self.sha) }
        try? FileManager.default.removeItem(at: directory)
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return GitRevision(sha: sha, message: "commit \(sha)")
    }
}

/// applyされたマニフェストの内容を覚えておき、diffでは現在のマニフェストと比べるクラスタ。
final class FakeCluster: ClusterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var namespaces: Set<String> = []
    private var appliedContent: Data?
    /// クラスタに存在する管理対象リソース。applyで増え、deleteでしか減らない。
    private var existing: [ResourceRef] = []
    private var drifted: Set<ResourceRef> = []
    private(set) var applyCount = 0
    private(set) var deletedRefs: [ResourceRef] = []

    var appliedCount: Int { lock.withLock { applyCount } }
    var deleted: [ResourceRef] { lock.withLock { deletedRefs } }
    var existingRefs: [ResourceRef] { lock.withLock { existing } }

    func drift(_ ref: ResourceRef) {
        lock.withLock { _ = drifted.insert(ref) }
    }

    func namespaceExists(_ namespace: String) async throws -> Bool {
        lock.withLock { namespaces.contains(namespace) }
    }

    func ensureNamespace(_ namespace: String) async throws {
        lock.withLock { _ = namespaces.insert(namespace) }
    }

    func diff(_ manifests: RenderedManifests, namespace: String) async throws -> DiffResult {
        let content = try Data(contentsOf: manifests.file)
        return lock.withLock {
            if appliedContent != content {
                return DiffResult(outOfSync: Set(manifests.resources), hasDiff: true)
            }
            return DiffResult(outOfSync: drifted, hasDiff: !drifted.isEmpty)
        }
    }

    func apply(_ manifests: RenderedManifests, namespace: String) async throws -> String {
        let content = try Data(contentsOf: manifests.file)
        lock.withLock {
            appliedContent = content
            for ref in manifests.resources where !existing.contains(ref) {
                existing.append(ref)
            }
            drifted = []
            applyCount += 1
        }
        return "applied"
    }

    func liveObjects(_ manifests: RenderedManifests, namespace: String) async throws -> [LiveObject] {
        let refs = lock.withLock { existing }.filter { manifests.resources.contains($0) }
        return try objects(refs)
    }

    func managedObjects(appName: String, namespace: String) async throws -> [LiveObject] {
        try objects(lock.withLock { existing })
    }

    func delete(_ objects: [LiveObject], namespace: String) async throws -> String {
        lock.withLock {
            let refs = objects.map(\.ref)
            existing.removeAll { refs.contains($0) }
            deletedRefs.append(contentsOf: refs)
        }
        return "deleted"
    }

    private func objects(_ refs: [ResourceRef]) throws -> [LiveObject] {
        try refs.map { ref in
            let object: [String: Any] = [
                "kind": ref.kind,
                "metadata": ["name": ref.name, "generation": 1],
                "spec": ["replicas": 1],
                "status": ["observedGeneration": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1],
            ]
            return LiveObject(ref: ref, json: try JSONSerialization.data(withJSONObject: object))
        }
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftcd-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func serviceYAML(name: String = "web") -> String {
    """
    apiVersion: v1
    kind: Service
    metadata:
      name: \(name)
    spec:
      selector: { app: \(name) }
      ports: [{ port: 80 }]
    """
}

func deploymentYAML(name: String = "web", replicas: Int = 1) -> String {
    """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: \(name)
    spec:
      replicas: \(replicas)
      selector:
        matchLabels: { app: \(name) }
      template:
        metadata:
          labels: { app: \(name) }
        spec:
          containers:
            - name: \(name)
              image: nginx:1.27
    """
}
