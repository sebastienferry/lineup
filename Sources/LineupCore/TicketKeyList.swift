import Foundation

/// Ticket keys the user chose by hand, kept in a JSON file of `~/.config/lineup` apart from the
/// settings, so choosing never rewrites them: the pinned tickets, which join the list whatever
/// the JQL says, and the hidden ones, which leave it.
public struct TicketKeyList: Sendable {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(file: String) {
        self.init(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lineup/\(file)"))
    }

    /// Tickets of any project pinned to the list.
    public static var pinned: TicketKeyList { TicketKeyList(file: "pinned.json") }
    /// Tickets taken out of the list and out of planning.
    public static var hidden: TicketKeyList { TicketKeyList(file: "hidden.json") }

    public func keys() -> [String] {
        guard let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    public func add(_ key: String) throws {
        var keys = keys()
        guard !keys.contains(key) else { return }
        keys.append(key)
        try save(keys)
    }

    public func remove(_ key: String) throws {
        try save(keys().filter { $0 != key })
    }

    private func save(_ keys: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(keys).write(to: url, options: .atomic)
    }
}

/// The text as a ticket key, "pe-2469" read as "PE-2469", or nil when it is not one.
public func ticketKey(fromQuery text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
    return trimmed.range(of: #"^[A-Z][A-Z0-9_]+-\d+$"#, options: .regularExpression) != nil ? trimmed : nil
}
