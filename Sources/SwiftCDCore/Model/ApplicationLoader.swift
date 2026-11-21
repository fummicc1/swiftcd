import Foundation
import Yams

public enum ApplicationLoader {
    /// ディレクトリ直下の `*.yaml` / `*.yml` をApplication定義として読み込む。
    /// `repoURL` の `~` と相対パスは、定義ファイルのある場所を基準に絶対パスへ展開する。
    public static func load(from directory: URL) throws -> [Application] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["yaml", "yml"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let apps = try files.map { file in
            var app = try YAMLDecoder().decode(Application.self, from: String(contentsOf: file, encoding: .utf8))
            app.source.repoURL = resolveRepoURL(app.source.repoURL, relativeTo: directory)
            return app
        }

        let names = apps.map(\.name)
        if let duplicate = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
            throw SwiftCDError.invalidManifest("duplicate application name '\(duplicate)'")
        }
        return apps
    }

    static func resolveRepoURL(_ repoURL: String, relativeTo base: URL) -> String {
        if repoURL.contains("://") || repoURL.contains("@") {
            return repoURL
        }
        let expanded = NSString(string: repoURL).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }
}
