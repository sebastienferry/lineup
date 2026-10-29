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

/// Registers the inbox's MCP server with Claude Desktop. Its chat does not read Claude Code's
/// servers: it lists its own in `claude_desktop_config.json`, which this edits in place, keeping
/// every other server and setting, after a backup of the file as it was.
public struct DesktopMCPSetup: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")) {
        self.url = url
    }

    /// Whether Claude Desktop has run on this Mac: its support folder exists.
    public var isAppPresent: Bool {
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// The command Claude Desktop runs for the server, or nil when it is not declared.
    public func registeredCommand() -> String? {
        guard let config = try? read(), let servers = config["mcpServers"] as? [String: Any],
              let server = servers[MCPSetup.serverName] as? [String: Any] else { return nil }
        return server["command"] as? String
    }

    public func isInstalled(command: String) -> Bool {
        registeredCommand().map { MCPSetup.sameFile($0, command) } ?? false
    }

    /// Declares `command mcp` as the server, replacing an earlier declaration of the same name.
    /// Claude Desktop reads the file when it starts.
    public func install(command: String) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        var config = exists ? try read() : [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[MCPSetup.serverName] = ["command": command, "args": ["mcp"]]
        config["mcpServers"] = servers

        if exists {
            let backup = url.appendingPathExtension("lineup-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        } else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        // The file can hold tokens of other servers: keep it readable by its owner only.
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The file as a JSON object; an unreadable one is an error rather than something to replace.
    public func read() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShellError("\(url.lastPathComponent) is not a JSON object; left untouched")
        }
        return object
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
