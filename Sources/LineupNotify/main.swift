import LineupCore
import Foundation

// lineup-notify: posts to and reads the Lineup inbox, and serves it to Claude over MCP.

let usage = """
    usage: lineup-notify post TITLE [--body TEXT] [--source NAME] [--url URL] [--level info|success|warning|error] [--key KEY]
           lineup-notify list [--all] [--json]
           lineup-notify read ID... | --all
           lineup-notify dismiss ID... | --read
           lineup-notify mcp           serve the inbox over MCP on stdin and stdout
           lineup-notify install-mcp   register that server with Claude Code, for every project
           lineup-notify version
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lineup-notify: \(message)\n".utf8))
    exit(1)
}

/// The values of `--name value` options, and the arguments left over.
func parse(_ arguments: ArraySlice<String>, flags: Set<String> = []) -> (options: [String: String], rest: [String]) {
    var options: [String: String] = [:], rest: [String] = []
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--") else {
            rest.append(argument)
            continue
        }
        let name = String(argument.dropFirst(2))
        if flags.contains(name) {
            options[name] = "true"
        } else {
            guard let value = iterator.next() else { fail("\(argument) needs a value") }
            options[name] = value
        }
    }
    return (options, rest)
}

let inbox = Inbox()
let arguments = CommandLine.arguments.dropFirst()

do {
    switch arguments.first {
    case "post":
        let (options, rest) = parse(arguments.dropFirst())
        guard !rest.isEmpty else { fail("post needs a title") }
        let levelName = options["level"] ?? "info"
        guard let level = InboxItem.Level(rawValue: levelName) else { fail("unknown level \(levelName)") }
        let item = try inbox.post(
            source: options["source"] ?? "cli",
            title: rest.joined(separator: " "),
            body: options["body"],
            url: options["url"],
            level: level,
            key: options["key"]
        )
        print(item.id)
    case "list":
        let (options, _) = parse(arguments.dropFirst(), flags: ["all", "json"])
        let items = inbox.items().filter { options["all"] != nil || !$0.isRead }
        if options["json"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(items), as: UTF8.self))
        } else {
            for item in items {
                let time = localMinute(item.createdAt)
                print("\(item.id)  \(time)  \(item.isRead ? " " : "•") [\(item.source)] \(item.title)")
            }
        }
    case "read":
        let (options, rest) = parse(arguments.dropFirst(), flags: ["all"])
        guard !rest.isEmpty || options["all"] != nil else { fail("read needs ids, or --all") }
        print(try inbox.markRead(ids: options["all"] != nil ? nil : rest))
    case "dismiss":
        let (options, rest) = parse(arguments.dropFirst(), flags: ["read"])
        guard !rest.isEmpty || options["read"] != nil else { fail("dismiss needs ids, or --read") }
        print(try inbox.dismiss(ids: options["read"] != nil ? nil : rest))
    case "mcp":
        InboxMCP(inbox: inbox, version: appVersion()).serve()
    case "install-mcp":
        let command = notifyExecutablePath()
        try await MCPSetup(claudePath: Config.load().resolvedClaudePath).install(command: command)
        print("Registered the \(MCPSetup.serverName) MCP server with Claude Code: \(command) mcp")
    case "version", "--version":
        print(appVersion())
    case "-h", "--help", "help":
        print(usage)
    default:
        fail("unknown command\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
