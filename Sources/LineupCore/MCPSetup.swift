import Foundation

/// Registers the inbox's MCP server with Claude Code, for every project, through `claude mcp`.
public struct MCPSetup: Sendable {
    public static let serverName = "inbox"
    let claudePath: String
    let runner: CommandRunner

    public init(claudePath: String, runner: CommandRunner = ProcessRunner()) {
        self.claudePath = claudePath
        self.runner = runner
    }

    /// The command Claude Code runs for the server, or nil when it is not registered.
    public func registeredCommand() async -> String? {
        guard let result = try? await runner.run(claudePath, ["mcp", "get", Self.serverName]), result.exitCode == 0 else { return nil }
        return Self.command(inGetOutput: result.stdout)
    }

    /// Whether the server is registered and runs this very binary, through a link or not.
    public func isInstalled(command: String) async -> Bool {
        guard let registered = await registeredCommand() else { return false }
        return Self.sameFile(registered, command)
    }

    /// Registers `command mcp` as the server, replacing an earlier registration.
    public func install(command: String) async throws {
        _ = try? await runner.run(claudePath, ["mcp", "remove", Self.serverName, "-s", "user"])
        _ = try await runner.output(claudePath, ["mcp", "add", "--scope", "user", Self.serverName, "--", command, "mcp"])
    }

    /// The "Command:" line of `claude mcp get`.
    static func command(inGetOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Command:") {
                return trimmed.dropFirst("Command:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func sameFile(_ a: String, _ b: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        }
        return resolved(a) == resolved(b)
    }
}

/// The running executable, its links followed: inside `Lineup.app` for the app and for
/// `lineup-notify` reached through `~/.local/bin`.
private var executableURL: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

/// The version of the app bundle the running executable sits in, "dev" outside a bundle.
public func appVersion() -> String {
    guard let app = executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
          app.pathExtension == "app" else { return "dev" }
    return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

/// The `lineup-notify` beside the running executable: in the bundle, or in the build folder.
public func notifyExecutablePath() -> String {
    (executableURL?.deletingLastPathComponent().appendingPathComponent("lineup-notify").path) ?? "lineup-notify"
}
