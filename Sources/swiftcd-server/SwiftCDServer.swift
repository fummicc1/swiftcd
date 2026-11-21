import ArgumentParser
import Foundation
import Hummingbird
import SwiftCDCore

@main
struct SwiftCDServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftcd-server",
        abstract: "Gitのマニフェストをローカルk8sへ同期するミニArgoCDサーバー")

    @Option(help: "Application定義（*.yaml）を置いたディレクトリ")
    var apps: String = "examples/apps"

    @Option(help: "待ち受けホスト")
    var host: String = "127.0.0.1"

    @Option(help: "待ち受けポート")
    var port: Int = 8080

    @Option(help: "reconcile間隔（秒）")
    var interval: Int = 30

    @Option(help: "clone先などの作業ディレクトリ")
    var workDir: String = "~/.swiftcd"

    // 普段使いの本番クラスタなどへ誤ってapplyしないよう、既定はkindのcontextに固定する。
    @Option(help: "kubectlのcontext")
    var context: String = "kind-swiftcd"

    func run() async throws {
        let appsURL = URL(fileURLWithPath: apps).standardizedFileURL
        let applications = try ApplicationLoader.load(from: appsURL)
        print("loaded \(applications.count) application(s) from \(appsURL.path): \(applications.map(\.name).joined(separator: ", "))")

        let store = AppStore(
            apps: applications,
            git: CLIGitClient(),
            cluster: KubectlClient(context: context),
            workDirectory: URL(fileURLWithPath: NSString(string: workDir).expandingTildeInPath),
            interval: .seconds(interval))
        await store.startAll()

        let router = Router()
        Routes.register(on: router, store: store)

        let app = Hummingbird.Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port)))
        print("SwiftCD UI: http://\(host):\(port)")
        try await app.runService()
        await store.stopAll()
    }
}
