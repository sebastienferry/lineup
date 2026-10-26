import Foundation

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ShellError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Runs a command line tool and collects what it printed. A protocol so the clients can be
/// tested against canned output.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ShellResult
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError("cannot start \(executable): \(error.localizedDescription)"))
                    return
                }
                // Read before waiting, so a large output cannot fill the pipe and block the tool.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self)
                ))
            }
        }
    }
}

extension CommandRunner {
    /// Runs the tool and answers its output, or throws with what it said when it failed.
    func output(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = try await run(executable, arguments)
        guard result.exitCode == 0 else {
            let said = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (executable as NSString).lastPathComponent
            throw ShellError("\(name) \(arguments.first ?? ""): \(said.isEmpty ? "exit \(result.exitCode)" : String(said.prefix(200)))")
        }
        return result.stdout
    }
}
