import Foundation

/// A notification any tool posted to the inbox: a script, a CI job, a Claude Code hook, Claude
/// itself through the MCP server.
public struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case info, success, warning, error
    }

    public let id: String
    /// Who posted it, free text: "ci", "claude", "deploy".
    public let source: String
    public let title: String
    public let body: String?
    public let url: String?
    public let level: Level
    /// A posting with the key of an earlier one replaces it, so a job that reports the same
    /// thing again leaves one notification, unread again.
    public let key: String?
    public let createdAt: Date
    public var readAt: Date?

    public var isRead: Bool { readAt != nil }

    public init(id: String, source: String, title: String, body: String?, url: String?, level: Level, key: String?, createdAt: Date, readAt: Date? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.body = body
        self.url = url
        self.level = level
        self.key = key
        self.createdAt = createdAt
        self.readAt = readAt
    }
}

/// The notifications, kept in `~/.config/lineup/inbox.json`. The app, the `lineup-notify`
/// command line and every MCP server write to it, each change under a lock on a file beside it.
public struct Inbox: Sendable {
    let url: URL
    /// The most notifications kept; the oldest go first.
    public static let capacity = 500
    /// Read notifications older than this are dropped on the next change.
    public static let keepReadDays = 14

    public init(url: URL = Inbox.defaultURL) {
        self.url = url
    }

    /// `$LINEUP_INBOX` when set, for a separate inbox, else the one the app shows.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["LINEUP_INBOX"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lineup/inbox.json")
    }

    /// Every notification, newest first.
    public func items() -> [InboxItem] {
        guard let data = try? Data(contentsOf: url), let items = try? Self.decoder.decode([InboxItem].self, from: data) else { return [] }
        return items.reversed()
    }

    /// When the inbox last changed, to reload only then.
    public func modifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @discardableResult
    public func post(source: String, title: String, body: String? = nil, url link: String? = nil, level: InboxItem.Level = .info, key: String? = nil, now: Date = Date()) throws -> InboxItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ShellError("a notification needs a title") }
        let item = InboxItem(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            source: source.isEmpty ? "unknown" : source,
            title: title,
            body: body.flatMap { $0.isEmpty ? nil : $0 },
            url: link.flatMap { $0.isEmpty ? nil : $0 },
            level: level,
            key: key.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: now
        )
        try change(now: now) { items in
            if let key = item.key { items.removeAll { $0.key == key && $0.source == item.source } }
            items.append(item)
        }
        return item
    }

    /// Marks the notifications read, all of them when `ids` is nil; answers how many changed.
    @discardableResult
    public func markRead(ids: [String]?, now: Date = Date()) throws -> Int {
        try change(now: now) { items in
            var count = 0
            for index in items.indices where items[index].readAt == nil && (ids?.contains(items[index].id) ?? true) {
                items[index].readAt = now
                count += 1
            }
            return count
        }
    }

    /// Removes the notifications, or every read one when `ids` is nil; answers how many went.
    @discardableResult
    public func dismiss(ids: [String]?, now: Date = Date()) throws -> Int {
        try change(now: now) { items in
            let before = items.count
            items.removeAll { item in ids.map { $0.contains(item.id) } ?? item.isRead }
            return before - items.count
        }
    }

    /// Reads, changes and writes the inbox under the lock, then trims it.
    private func change<T>(now: Date, _ body: (inout [InboxItem]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw ShellError("cannot lock \(url.path)") }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var items: [InboxItem] = Array(self.items().reversed())
        let result = try body(&items)
        let cutoff = now.addingTimeInterval(-Double(Self.keepReadDays) * 86_400)
        items.removeAll { ($0.readAt ?? .distantFuture) < cutoff }
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        try Self.encoder.encode(items).write(to: url, options: .atomic)
        return result
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension InboxItem {
    /// Whether every word of the query appears in its source, title or body.
    public func matches(_ words: [String]) -> Bool {
        matchesAll(words, in: [source, title, body ?? ""])
    }
}
