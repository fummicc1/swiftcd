import Foundation
import Testing
@testable import SwiftCDCore

@Suite struct AppControllerTests {
    let deployment = ResourceRef(group: "apps", kind: "Deployment", name: "web")

    private func makeController(
        automated: Bool, git: FakeGit, cluster: FakeCluster, namespace: String = "demo", workDirectory: URL? = nil
    ) throws -> AppController {
        let app = Application(
            name: "demo",
            source: .init(repoURL: "/unused", path: "manifests"),
            destination: .init(namespace: namespace),
            syncPolicy: .init(automated: automated))
        return AppController(
            app: app, git: git, cluster: cluster, workDirectory: try workDirectory ?? temporaryDirectory())
    }

    @Test func 自動Syncが有効なら初回refreshで同期される() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, git: git, cluster: cluster)

        let status = await controller.refresh()

        #expect(cluster.appliedCount == 1)
        #expect(status.sync == .synced)
        #expect(status.health == .healthy)
        #expect(status.lastSyncedRevision == "aaaaaaa")
        #expect(status.resources.map(\.ref) == [deployment])
        #expect(status.error == nil)
    }

    @Test func 新しいコミットは自動Syncされる() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, git: git, cluster: cluster)
        await controller.refresh()

        git.commit(files: ["manifests/deploy.yaml": deploymentYAML(replicas: 3)], sha: "bbbbbbb")
        let status = await controller.refresh()

        #expect(cluster.appliedCount == 2)
        #expect(status.sync == .synced)
        #expect(status.revision == "bbbbbbb")
        #expect(status.lastSyncedRevision == "bbbbbbb")
    }

    @Test func 同じリビジョンへのドリフトは自動で戻さずOutOfSyncにする() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let controller = try makeController(automated: true, git: git, cluster: cluster)
        await controller.refresh()

        cluster.drift(deployment)
        let status = await controller.refresh()

        #expect(cluster.appliedCount == 1)
        #expect(status.sync == .outOfSync)
        #expect(status.resources.first?.sync == .outOfSync)
    }

    @Test func 再起動してもSync済みのリビジョンへのドリフトは自動で戻さない() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let workDirectory = try temporaryDirectory()
        try await makeController(automated: true, git: git, cluster: cluster, workDirectory: workDirectory).refresh()

        cluster.drift(deployment)
        let restarted = try makeController(automated: true, git: git, cluster: cluster, workDirectory: workDirectory)
        let status = await restarted.refresh()

        #expect(cluster.appliedCount == 1)
        #expect(status.sync == .outOfSync)
        #expect(status.lastSyncedRevision == "aaaaaaa")
    }

    @Test func 再起動中に入ったコミットは自動Syncされる() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let workDirectory = try temporaryDirectory()
        try await makeController(automated: true, git: git, cluster: cluster, workDirectory: workDirectory).refresh()

        git.commit(files: ["manifests/deploy.yaml": deploymentYAML(replicas: 3)], sha: "bbbbbbb")
        let restarted = try makeController(automated: true, git: git, cluster: cluster, workDirectory: workDirectory)
        let status = await restarted.refresh()

        #expect(cluster.appliedCount == 2)
        #expect(status.lastSyncedRevision == "bbbbbbb")
    }

    @Test func Application定義が変わっていたら保存したSync済みリビジョンは使わない() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let workDirectory = try temporaryDirectory()
        try await makeController(automated: true, git: git, cluster: cluster, workDirectory: workDirectory).refresh()

        cluster.drift(deployment)
        let restarted = try makeController(
            automated: true, git: git, cluster: cluster, namespace: "other", workDirectory: workDirectory)
        let status = await restarted.refresh()

        #expect(cluster.appliedCount == 2)
        #expect(status.sync == .synced)
    }

    @Test func 手動Syncのアプリはsyncを呼ぶまで同期しない() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let controller = try makeController(automated: false, git: git, cluster: cluster)

        let before = await controller.refresh()
        #expect(cluster.appliedCount == 0)
        #expect(before.sync == .outOfSync)
        #expect(before.health == .missing)

        let after = await controller.sync()
        #expect(cluster.appliedCount == 1)
        #expect(after.sync == .synced)
        #expect(after.health == .healthy)
    }

    @Test func パスが存在しなければエラーを記録する() async throws {
        let git = FakeGit(files: ["other/deploy.yaml": deploymentYAML()])
        let controller = try makeController(automated: true, git: git, cluster: FakeCluster())

        let status = await controller.refresh()

        #expect(status.sync == .unknown)
        #expect(status.error?.contains("not found") == true)
    }

    @Test func refreshとsyncを同時に呼んでも直列に処理される() async throws {
        let git = FakeGit(files: ["manifests/deploy.yaml": deploymentYAML()])
        let cluster = FakeCluster()
        let controller = try makeController(automated: false, git: git, cluster: cluster)

        async let a = controller.refresh()
        async let b = controller.sync()
        async let c = controller.refresh()
        _ = await (a, b, c)

        let status = await controller.status
        #expect(status.phase == .idle)
        #expect(status.sync == .synced)
    }
}
