import ArgumentParser
import Foundation
import SwiftCDCore

@main
struct SwiftCDCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftcd",
        abstract: "SwiftCDサーバーを操作するCLI",
        subcommands: [AppCommand.self])
}

struct ServerOptions: ParsableArguments {
    @Option(help: "SwiftCDサーバーのURL")
    var server: String = "http://127.0.0.1:8080"

    func request(_ method: String, _ path: String) async throws -> Data {
        guard let url = URL(string: server + path) else {
            throw ValidationError("invalid server URL: \(server)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ValidationError("HTTP \(code): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Applicationの操作",
        subcommands: [List.self, Get.self, Sync.self, Refresh.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Application一覧を表示する")
        @OptionGroup var options: ServerOptions

        func run() async throws {
            let apps = try APICoding.decoder.decode([AppStatus].self, from: await options.request("GET", "/api/apps"))
            let rows = apps.map { app in
                [app.name, app.sync.rawValue, app.health.rawValue, String((app.revision ?? "-").prefix(7)),
                 app.destination.namespace, (app.automated ? "auto" : "manual") + (app.prune ? "+prune" : "")]
            }
            printTable(header: ["NAME", "SYNC", "HEALTH", "REVISION", "NAMESPACE", "POLICY"], rows: rows)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Applicationの詳細を表示する")
        @OptionGroup var options: ServerOptions
        @Argument var name: String

        func run() async throws {
            printDetail(try await fetch(options, "GET", "/api/apps/\(name)"))
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Applicationを同期する")
        @OptionGroup var options: ServerOptions
        @Argument var name: String
        @Flag(help: "Gitから消えたリソースをクラスタからも削除する")
        var prune = false

        func run() async throws {
            printDetail(try await fetch(options, "POST", "/api/apps/\(name)/sync\(prune ? "?prune=true" : "")"))
        }
    }

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Gitとクラスタを再比較する")
        @OptionGroup var options: ServerOptions
        @Argument var name: String

        func run() async throws {
            printDetail(try await fetch(options, "POST", "/api/apps/\(name)/refresh"))
        }
    }
}

private func fetch(_ options: ServerOptions, _ method: String, _ path: String) async throws -> AppStatus {
    try APICoding.decoder.decode(AppStatus.self, from: await options.request(method, path))
}

private func printDetail(_ app: AppStatus) {
    print("""
    Name:       \(app.name)
    Repo:       \(app.source.repoURL) (path: \(app.source.path), revision: \(app.source.targetRevision))
    Namespace:  \(app.destination.namespace)
    Sync:       \(app.sync.rawValue)
    Health:     \(app.health.rawValue)
    Revision:   \(app.revision ?? "-") \(app.revisionMessage ?? "")
    LastSynced: \(app.lastSyncedRevision ?? "-")
    """)
    if let error = app.error {
        print("Error:      \(error)")
    }
    print("")
    printTable(
        header: ["KIND", "NAME", "SYNC", "HEALTH", "MESSAGE"],
        rows: app.resources.map {
            [$0.ref.kind, $0.ref.name, $0.sync.rawValue + ($0.requiresPruning ? " (prune)" : ""),
             $0.health.rawValue, $0.message ?? ""]
        })
}

private func printTable(header: [String], rows: [[String]]) {
    let all = [header] + rows
    let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
    for row in all {
        print(row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}
