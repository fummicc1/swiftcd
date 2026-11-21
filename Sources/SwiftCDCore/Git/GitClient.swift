import Foundation

public struct GitRevision: Sendable, Equatable {
    public var sha: String
    public var message: String

    public init(sha: String, message: String) {
        self.sha = sha
        self.message = message
    }
}

public protocol GitClient: Sendable {
    /// `repoURL` を `directory` にclone（2回目以降はfetch）し、`revision` をcheckoutする。
    func checkout(repoURL: String, revision: String, into directory: URL) async throws -> GitRevision
}

public struct CLIGitClient: GitClient {
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func checkout(repoURL: String, revision: String, into directory: URL) async throws -> GitRevision {
        let gitDir = directory.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            try await runner.runChecked(["git", "-C", directory.path, "remote", "set-url", "origin", repoURL])
            try await runner.runChecked(["git", "-C", directory.path, "fetch", "--prune", "--tags", "--force", "origin"])
        } else {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await runner.runChecked(["git", "clone", "--quiet", repoURL, directory.path])
        }

        let sha = try await resolve(revision: revision, in: directory)
        try await runner.runChecked(["git", "-C", directory.path, "checkout", "--quiet", "--force", "--detach", sha])
        let message = try await runner.runChecked(["git", "-C", directory.path, "log", "-1", "--format=%s", sha])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitRevision(sha: sha, message: message)
    }

    /// ブランチ名はリモート側（origin/<branch>）を優先して解決し、だめならタグやSHAとして解決する。
    private func resolve(revision: String, in directory: URL) async throws -> String {
        for candidate in ["origin/\(revision)", revision] {
            let result = try await runner.run(
                ["git", "-C", directory.path, "rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"],
                in: nil)
            if result.exitCode == 0 {
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw SwiftCDError.revisionNotFound(revision)
    }
}

public enum SwiftCDError: Error, CustomStringConvertible, Equatable {
    case revisionNotFound(String)
    case pathNotFound(String)
    case invalidManifest(String)
    case appNotFound(String)

    public var description: String {
        switch self {
        case .revisionNotFound(let rev): "revision '\(rev)' not found"
        case .pathNotFound(let path): "path '\(path)' not found in repository"
        case .invalidManifest(let detail): "invalid manifest: \(detail)"
        case .appNotFound(let name): "application '\(name)' not found"
        }
    }
}
