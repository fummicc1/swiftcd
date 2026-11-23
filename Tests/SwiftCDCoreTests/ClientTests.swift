import Foundation
import Testing
@testable import SwiftCDCore

@Suite struct KubectlClientTests {
    @Test func diff出力から差分のあるリソースを特定する() {
        let output = """
        diff -u -N /tmp/LIVE-123/apps.v1.Deployment.demo.web /tmp/MERGED-123/apps.v1.Deployment.demo.web
        --- /tmp/LIVE-123/apps.v1.Deployment.demo.web
        +++ /tmp/MERGED-123/apps.v1.Deployment.demo.web
        -  replicas: 1
        +  replicas: 3
        diff -u -N /tmp/LIVE-123/v1.ConfigMap.demo.web /tmp/MERGED-123/v1.ConfigMap.demo.web
        """
        let deployment = ResourceRef(group: "apps", kind: "Deployment", name: "web")
        let service = ResourceRef(group: "", kind: "Service", name: "web")
        let configMap = ResourceRef(group: "", kind: "ConfigMap", name: "web")

        let result = KubectlClient.parseDiffTargets(output, candidates: [deployment, service, configMap])

        #expect(result == [deployment, configMap])
    }

    @Test func getの結果は単体でもListでも読める() throws {
        let single = #"{"apiVersion":"v1","kind":"Service","metadata":{"name":"web"}}"#
        #expect(try KubectlClient.parseLiveObjects(Data(single.utf8)).map(\.ref) == [
            ResourceRef(group: "", kind: "Service", name: "web"),
        ])

        let list = #"{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"a"}},{"apiVersion":"v1","kind":"Service","metadata":{"name":"b"}}]}"#
        #expect(try KubectlClient.parseLiveObjects(Data(list.utf8)).map(\.ref.name) == ["a", "b"])
    }
}

@Suite struct ProcessRunnerTests {
    @Test func 制限時間内に終わったコマンドは結果を返す() async throws {
        let result = try await ProcessRunner(timeout: .seconds(5)).run(["echo", "hello"], in: nil)

        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello\n")
    }

    @Test func 制限時間を超えたコマンドは打ち切ってエラーにする() async throws {
        let runner = ProcessRunner(timeout: .milliseconds(200))
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await #expect(throws: CommandTimeoutError.self) {
                try await runner.run(["sleep", "10"], in: nil)
            }
        }

        #expect(elapsed < .seconds(5))
    }
}

@Suite struct CLIGitClientTests {
    private let runner = ProcessRunner()

    private func makeRepo() async throws -> URL {
        let repo = try temporaryDirectory()
        try await runner.runChecked(["git", "init", "--quiet", "-b", "main", repo.path])
        try await commit(in: repo, file: "a.txt", content: "v1", message: "first")
        return repo
    }

    private func commit(in repo: URL, file: String, content: String, message: String) async throws {
        try content.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await runner.runChecked(["git", "-C", repo.path, "add", "."])
        try await runner.runChecked([
            "git", "-C", repo.path, "-c", "user.name=test", "-c", "user.email=test@example.com",
            "commit", "--quiet", "-m", message,
        ])
    }

    @Test func cloneして最新コミットをcheckoutし追加コミットはfetchで取り込む() async throws {
        let repo = try await makeRepo()
        let checkout = try temporaryDirectory().appendingPathComponent("checkout")
        let git = CLIGitClient()

        let first = try await git.checkout(repoURL: repo.path, revision: "main", into: checkout)
        #expect(first.message == "first")
        #expect(try String(contentsOf: checkout.appendingPathComponent("a.txt"), encoding: .utf8) == "v1")

        try await commit(in: repo, file: "a.txt", content: "v2", message: "second")
        let second = try await git.checkout(repoURL: repo.path, revision: "main", into: checkout)
        #expect(second.message == "second")
        #expect(second.sha != first.sha)
        #expect(try String(contentsOf: checkout.appendingPathComponent("a.txt"), encoding: .utf8) == "v2")

        let head = try await git.checkout(repoURL: repo.path, revision: "HEAD", into: checkout)
        #expect(head.sha == second.sha)
    }

    @Test func 存在しないリビジョンはエラー() async throws {
        let repo = try await makeRepo()
        let checkout = try temporaryDirectory().appendingPathComponent("checkout")

        await #expect(throws: SwiftCDError.revisionNotFound("nope")) {
            try await CLIGitClient().checkout(repoURL: repo.path, revision: "nope", into: checkout)
        }
    }
}

@Suite struct ApplicationLoaderTests {
    @Test func 定義を読み込み相対パスのrepoURLを展開する() throws {
        let dir = try temporaryDirectory()
        try """
        name: guestbook
        source:
          repoURL: ../repo
          path: guestbook
        destination:
          namespace: guestbook
        syncPolicy:
          automated: true
        """.write(to: dir.appendingPathComponent("guestbook.yaml"), atomically: true, encoding: .utf8)

        let apps = try ApplicationLoader.load(from: dir)

        #expect(apps.count == 1)
        #expect(apps[0].source.repoURL == dir.deletingLastPathComponent().appendingPathComponent("repo").standardizedFileURL.path)
        #expect(apps[0].source.targetRevision == "HEAD")
        #expect(apps[0].syncPolicy.automated)
    }

    @Test func URL形式のrepoURLはそのまま使う() {
        let base = URL(fileURLWithPath: "/base")
        #expect(ApplicationLoader.resolveRepoURL("https://github.com/a/b.git", relativeTo: base) == "https://github.com/a/b.git")
        #expect(ApplicationLoader.resolveRepoURL("/abs/repo", relativeTo: base) == "/abs/repo")
    }
}
