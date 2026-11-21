import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CommandError: Error, CustomStringConvertible, Sendable {
    public var command: [String]
    public var result: CommandResult

    public var description: String {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return "`\(command.joined(separator: " "))` failed (exit \(result.exitCode)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public protocol CommandRunner: Sendable {
    func run(_ arguments: [String], in directory: URL?) async throws -> CommandResult
}

extension CommandRunner {
    /// 終了コードが0以外なら `CommandError` を投げる。
    @discardableResult
    public func runChecked(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        let result = try await run(arguments, in: directory)
        guard result.exitCode == 0 else {
            throw CommandError(command: arguments, result: result)
        }
        return result
    }
}

/// `/usr/bin/env` 経由で実行し、PATH上の git や kubectl を解決する。
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                if let directory {
                    process.currentDirectoryURL = directory
                }
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // 片方のパイプが詰まるとデッドロックするため、stderrは別スレッドで読む。
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrBox.data, as: UTF8.self)
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
