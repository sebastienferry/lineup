import Foundation

/// Tickets of any project the user pinned to the list by hand, kept in
/// `~/.config/lineup/pinned.json` apart from the settings, so pinning never rewrites them.
public struct PinnedTickets: Sendable {
    let url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lineup/pinned.json")) {
        self.url = url
    }

    public func keys() -> [String] {
        guard let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    public func pin(_ key: String) throws {
        var keys = keys()
        guard !keys.contains(key) else { return }
        keys.append(key)
        try save(keys)
    }

    public func unpin(_ key: String) throws {
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
