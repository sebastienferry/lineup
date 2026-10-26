import Foundation

/// An open Jira ticket, as the list shows it.
public struct Ticket: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let summary: String
    public let priority: String
    public let status: String
    public let created: Date?

    public init(key: String, summary: String, priority: String, status: String, created: Date?) {
        self.key = key
        self.summary = summary
        self.priority = priority
        self.status = status
        self.created = created
    }
}

/// A calendar event of the agenda.
public struct AgendaEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let meetURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, meetURL: URL?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.meetURL = meetURL
    }
}

/// Jira's two priority schemes, highest first: the default one, and the older one some projects
/// keep. A step up or down stays within the ticket's own scheme.
public let priorityOrder = ["Highest", "High", "Medium", "Low", "Lowest"]
public let legacyPriorityOrder = ["Blocker", "Critical", "Major", "Minor", "Trivial"]

/// A priority's level, 0 the highest, the same for both schemes so their tickets sort together:
/// Blocker sits with Highest, Major with Medium.
public func priorityRank(_ priority: String) -> Int {
    priorityOrder.firstIndex(of: priority) ?? legacyPriorityOrder.firstIndex(of: priority) ?? priorityOrder.count
}

/// Tickets sorted highest priority first, oldest first within a priority, as the JQL already
/// asks; sorting again keeps the order right after a local priority change.
public func sortedByPriority(_ tickets: [Ticket]) -> [Ticket] {
    let rank = priorityRank
    return tickets.enumerated().sorted { a, b in
        let ra = rank(a.element.priority), rb = rank(b.element.priority)
        return ra != rb ? ra < rb : a.offset < b.offset
    }.map(\.element)
}

/// The priority one step up (`-1`) or down (`+1`), or nil at either end.
public func steppedPriority(_ priority: String, by step: Int) -> String? {
    for scheme in [priorityOrder, legacyPriorityOrder] {
        guard let index = scheme.firstIndex(of: priority) else { continue }
        let target = index + step
        return scheme.indices.contains(target) ? scheme[target] : nil
    }
    return nil
}

/// The first `PROJECT-123` key of the text, for one of the projects.
public func firstTicketKey(in text: String, projects: [String]) -> String? {
    guard !projects.isEmpty else { return nil }
    let alternatives = projects.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    guard let regex = try? NSRegularExpression(pattern: "\\b(?:\(alternatives))-\\d+\\b") else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else {
        return nil
    }
    return String(text[swiftRange])
}

/// The list view's two parts: the tickets with a block in the calendar, and the others, by
/// priority.
public struct Backlog: Equatable, Sendable {
    /// A calendar block that names an open ticket: the ticket has time set aside for it.
    public struct Blocked: Identifiable, Equatable, Sendable {
        public var id: String { event.id }
        public let event: AgendaEvent
        public let ticket: Ticket
    }

    /// Tickets with a block in the calendar, soonest first.
    public let blocked: [Blocked]
    public let unscheduled: [Ticket]

    /// `events` are the upcoming calendar events; the ones whose title names an open ticket
    /// take that ticket out of the unscheduled ones until they are over.
    public init(tickets: [Ticket], events: [AgendaEvent] = [], projects: [String], now: Date = Date()) {
        let byKey = Dictionary(tickets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var linked = Set<String>()
        blocked = events
            .filter { $0.end > now && !$0.isAllDay }
            .sorted { $0.start < $1.start }
            .compactMap { event in
                guard let key = firstTicketKey(in: event.title, projects: projects), let ticket = byKey[key] else { return nil }
                linked.insert(key)
                return Blocked(event: event, ticket: ticket)
            }
        unscheduled = sortedByPriority(tickets.filter { !linked.contains($0.key) })
    }

    private init(blocked: [Blocked], unscheduled: [Ticket]) {
        self.blocked = blocked
        self.unscheduled = unscheduled
    }

    /// The rows that match every word of the query, ignoring case and accents: a ticket by its
    /// key, summary, status or priority, a block also by its event title.
    public func filtered(by query: String) -> Backlog {
        let words = searchWords(query)
        guard !words.isEmpty else { return self }
        func matches(_ ticket: Ticket) -> Bool {
            matchesAll(words, in: [ticket.key, ticket.summary, ticket.status, ticket.priority])
        }
        return Backlog(
            blocked: blocked.filter { matches($0.ticket) || matchesAll(words, in: [$0.event.title]) },
            unscheduled: unscheduled.filter(matches)
        )
    }
}

/// The query's words, folded for comparison.
public func searchWords(_ query: String) -> [String] {
    query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
}

/// Whether every word appears in at least one of the fields.
public func matchesAll(_ words: [String], in fields: [String]) -> Bool {
    let haystack = fields.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return words.allSatisfy { haystack.contains($0) }
}
