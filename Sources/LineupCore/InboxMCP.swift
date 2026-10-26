import Foundation

/// The inbox as an MCP server over stdio: one JSON-RPC message per line in, one per line out.
/// Local and unauthenticated, as Claude Code starts it as a child process; nothing listens on
/// the network.
public struct InboxMCP: Sendable {
    let inbox: Inbox
    let version: String

    public init(inbox: Inbox = Inbox(), version: String = "0.0.0") {
        self.inbox = inbox
        self.version = version
    }

    /// Serves until stdin closes.
    public func serve() {
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// The reply to one message, or nil for a notification, which takes none.
    public func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        // A message without an id is a notification ("notifications/initialized"): no reply.
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return encode(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "lineup-notify", "version": version],
                "instructions": Self.instructions,
            ] as [String: Any]])
        case "ping":
            return encode(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
        case "tools/list":
            return encode(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result: [String: Any]
            do {
                result = ["content": [["type": "text", "text": try call(name, arguments)]]]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    /// Runs a tool and answers its text.
    func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        switch name {
        case "list_notifications":
            let unreadOnly = arguments["unread_only"] as? Bool ?? true
            let source = arguments["source"] as? String
            let limit = max(arguments["limit"] as? Int ?? 20, 1)
            let all = inbox.items()
            let matching = all.filter { (!unreadOnly || !$0.isRead) && (source == nil || $0.source == source) }
            let listed = Array(matching.prefix(limit))
            let payload: [String: Any] = [
                "unread": all.filter { !$0.isRead }.count,
                "matching": matching.count,
                "notifications": listed.map(Self.json),
            ]
            return encode(payload)
        case "post_notification":
            guard let title = arguments["title"] as? String else { throw ShellError("title is required") }
            let levelName = arguments["level"] as? String ?? "info"
            guard let level = InboxItem.Level(rawValue: levelName) else { throw ShellError("unknown level \(levelName)") }
            let item = try inbox.post(
                source: arguments["source"] as? String ?? "claude",
                title: title,
                body: arguments["body"] as? String,
                url: arguments["url"] as? String,
                level: level,
                key: arguments["key"] as? String
            )
            return encode(["posted": Self.json(item)])
        case "mark_read":
            return encode(["marked": try inbox.markRead(ids: try ids(arguments))])
        case "dismiss_notifications":
            return encode(["dismissed": try inbox.dismiss(ids: try ids(arguments))])
        default:
            throw ShellError("unknown tool \(name)")
        }
    }

    /// The `ids` argument, or nil for every one when `all` is true; one of the two is required.
    private func ids(_ arguments: [String: Any]) throws -> [String]? {
        if let ids = arguments["ids"] as? [String], !ids.isEmpty { return ids }
        if arguments["all"] as? Bool == true { return nil }
        throw ShellError("give ids, or all: true")
    }

    static func json(_ item: InboxItem) -> [String: Any] {
        var json: [String: Any] = [
            "id": item.id,
            "source": item.source,
            "title": item.title,
            "level": item.level.rawValue,
            "created_at": iso(item.createdAt),
            "read": item.isRead,
        ]
        if let body = item.body { json["body"] = body }
        if let url = item.url { json["url"] = url }
        if let key = item.key { json["key"] = key }
        return json
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static let instructions = """
        A local inbox of notifications posted by the user's scripts, CI jobs, hooks and agents, \
        shown in the Lineup menu bar app. Call list_notifications to see what is new, \
        mark_read once you have handled or reported a notification, and post_notification to \
        tell the user something that should outlive this conversation, such as a long task finishing.
        """

    static let tools: [[String: Any]] = [
        [
            "name": "list_notifications",
            "description": "List the notifications of the inbox, newest first, with the number still unread.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "unread_only": ["type": "boolean", "description": "Only unread ones (default true)."],
                    "source": ["type": "string", "description": "Only those of this source, such as \"ci\"."],
                    "limit": ["type": "integer", "minimum": 1, "description": "At most this many (default 20)."],
                ],
            ] as [String: Any],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "post_notification",
            "description": "Post a notification to the user's inbox. A key replaces the earlier notification of the same source and key.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "One line."],
                    "body": ["type": "string", "description": "Details, a few lines at most."],
                    "source": ["type": "string", "description": "Who posts it (default \"claude\")."],
                    "url": ["type": "string", "description": "A link to open from the notification."],
                    "level": ["type": "string", "enum": InboxItem.Level.allCases.map(\.rawValue)],
                    "key": ["type": "string", "description": "Replaces the notification posted earlier with this key."],
                ],
                "required": ["title"],
            ] as [String: Any],
        ],
        [
            "name": "mark_read",
            "description": "Mark notifications read.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ids": ["type": "array", "items": ["type": "string"]],
                    "all": ["type": "boolean", "description": "Every unread notification."],
                ],
            ] as [String: Any],
            "annotations": ["idempotentHint": true],
        ],
        [
            "name": "dismiss_notifications",
            "description": "Remove notifications from the inbox.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ids": ["type": "array", "items": ["type": "string"]],
                    "all": ["type": "boolean", "description": "Every read notification."],
                ],
            ] as [String: Any],
            "annotations": ["destructiveHint": true],
        ],
    ]
}
