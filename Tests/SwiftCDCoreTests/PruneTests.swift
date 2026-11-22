import Foundation
import Testing
@testable import SwiftCDCore

@Suite struct PruneTests {
    let deployment = ResourceRef(group: "apps", kind: "Deployment", name: "web")
    let service = ResourceRef(group: "", kind: "Service", name: "web")
    let bothFiles = ["manifests/deploy.yaml": deploymentYAML(), "manifests/service.yaml": serviceYAML()]
    let deploymentOnly = ["manifests/deploy.yaml": deploymentYAML()]

    private func makeController(automated: Bool, prune: Bool, git: FakeGit, cluster: FakeCluster) throws -> AppController {
        let app = Application(
            name: "demo",
            source: .init(repoURL: "/unused", path: "manifests"),
            destination: .init(namespace: "demo"),
            syncPolicy: .init(automated: automated, prune: prune))
        return AppController(app: app, git: git, cluster: cluster, workDirectory: try temporaryDirectory())
    }

    @Test func pruneが無効ならGitから消えたリソースは残しOutOfSyncにする() async throws {
        let git = FakeGit(files: bothFiles)
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, prune: false, git: git, cluster: cluster)
        await controller.refresh()

        git.commit(files: deploymentOnly, sha: "bbbbbbb")
        let status = await controller.refresh()

        #expect(cluster.appliedCount == 2)
        #expect(cluster.deleted.isEmpty)
        #expect(cluster.existingRefs.contains(service))
        #expect(status.sync == .outOfSync)
        #expect(status.health == .healthy)
        let orphan = try #require(status.resources.first { $0.ref == service })
        #expect(orphan.requiresPruning)
        #expect(orphan.sync == .outOfSync)
    }

    @Test func 手動Syncでpruneを指定すると削除してSyncedになる() async throws {
        let git = FakeGit(files: bothFiles)
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, prune: false, git: git, cluster: cluster)
        await controller.refresh()
        git.commit(files: deploymentOnly, sha: "bbbbbbb")
        await controller.refresh()

        let status = await controller.sync(prune: true)

        #expect(cluster.deleted == [service])
        #expect(status.sync == .synced)
        #expect(status.resources.map(\.ref) == [deployment])
    }

    @Test func syncPolicyのpruneが有効なら自動Syncで削除する() async throws {
        let git = FakeGit(files: bothFiles)
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, prune: true, git: git, cluster: cluster)
        await controller.refresh()

        git.commit(files: deploymentOnly, sha: "bbbbbbb")
        let status = await controller.refresh()

        #expect(cluster.deleted == [service])
        #expect(status.sync == .synced)
    }

    @Test func 全マニフェストを消してもpruneできる() async throws {
        let git = FakeGit(files: bothFiles)
        let cluster = FakeCluster()
        let controller = try makeController(automated: false, prune: false, git: git, cluster: cluster)
        await controller.sync()

        git.commit(files: ["manifests/.keep": ""], sha: "bbbbbbb")
        let status = await controller.sync(prune: true)

        #expect(Set(cluster.deleted) == [deployment, service])
        #expect(status.sync == .synced)
        #expect(status.resources.isEmpty)
    }

    @Test func ownerReferencesを持つものと除外対象の種類はprune対象にしない() throws {
        func object(_ kind: String, _ name: String, owned: Bool = false) throws -> LiveObject {
            var metadata: [String: Any] = ["name": name]
            if owned {
                metadata["ownerReferences"] = [["kind": "Service", "name": "web"]]
            }
            return LiveObject(
                ref: ResourceRef(group: "", kind: kind, name: name),
                json: try JSONSerialization.data(withJSONObject: ["kind": kind, "metadata": metadata]))
        }
        let managed = [
            try object("Service", "web"),
            try object("ConfigMap", "old"),
            try object("Endpoints", "web"),
            try object("EndpointSlice", "web-abc", owned: true),
            try object("Pod", "web-123", owned: true),
        ]

        let orphans = PrunePlanner.orphans(desired: [service], managed: managed)

        #expect(orphans.map(\.ref) == [ResourceRef(group: "", kind: "ConfigMap", name: "old")])
    }
}
