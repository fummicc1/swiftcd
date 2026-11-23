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

public struct CommandTimeoutError: Error, CustomStringConvertible, Sendable {
    public var command: [String]
    public var timeout: Duration

    public var description: String {
        "`\(command.joined(separator: " "))` timed out after \(timeout)"
    }
}

/// `/usr/bin/env` 経由で実行し、PATH上の git や kubectl を解決する。
public struct ProcessRunner: CommandRunner {
    private static let killGracePeriod: Duration = .seconds(2)

    /// 固まったコマンドがアプリの操作キューを止め続けないよう、これを超えたら打ち切る。
    public let timeout: Duration

    public init(timeout: Duration = .seconds(120)) {
        self.timeout = timeout
    }

    public func run(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ResumeOnce(continuation)
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
                    resumer.resume(throwing: error)
                    return
                }

                // 子プロセスがパイプを開いたまま残ると読み取りが終わらないので、終了を待たずに呼び出し元へ返す。
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    resumer.resume(throwing: CommandTimeoutError(command: arguments, timeout: timeout))
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod.timeInterval) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: deadline)

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
                deadline.cancel()

                resumer.resume(returning: CommandResult(
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

/// タイムアウトと通常終了のどちらが先でも、continuationを1回だけ再開する。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(_ continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    func resume(returning result: CommandResult) {
        take()?.resume(returning: result)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<CommandResult, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
