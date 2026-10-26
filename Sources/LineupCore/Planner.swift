import Foundation

/// A slot Claude proposes for a ticket.
public struct PlanProposal: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let summary: String
    /// Local time, "YYYY-MM-DD HH:MM".
    public let at: String
    public let minutes: Int
    public let reason: String

    public init(key: String, summary: String, at: String, minutes: Int, reason: String) {
        self.key = key
        self.summary = summary
        self.at = at
        self.minutes = minutes
        self.reason = reason
    }
}

/// What a planning run answers: the slots that passed the checks, and why the others did not.
public struct Plan: Equatable, Sendable {
    public let proposals: [PlanProposal]
    public let rejected: [String]
}

/// A span of time already taken in the calendar.
public struct BusySlot: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let title: String

    public init(start: Date, end: Date, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Asks Claude, through the `claude` command line in print mode, where the tickets fit in the
/// coming days. Claude gets no tools and no context but this request: a system prompt of our
/// own replaces Claude Code's, with no MCP server, settings or slash commands, which keeps a
/// run near 1,500 tokens instead of the whole of Claude Code's context. The answer is checked
/// here before anything is offered: Claude proposes, the app decides what is valid.
public struct Planner: Sendable {
    let config: Config
    let runner: CommandRunner
    let timeZone: TimeZone

    public init(config: Config, runner: CommandRunner = ProcessRunner(), timeZone: TimeZone = .current) {
        self.config = config
        self.runner = runner
        self.timeZone = timeZone
    }

    static let systemPrompt = """
    You plan a software engineer's backlog into their calendar. You receive the tickets to \
    schedule, the busy slots of the coming days, the working hours and the current time. For \
    each ticket, choose one start time inside working hours, in the future, that does not \
    overlap a busy slot or another of your proposals, and an estimated duration in minutes \
    (multiples of 15, from 15 to 180). Put higher priorities earlier. Keep a ticket that cannot \
    fit out of the answer. Give each proposal a short reason in French (at most 12 words). \
    Answer only through the structured output, times as "YYYY-MM-DD HH:MM" in local time.
    """

    static let schema = """
    {"type":"object","properties":{"proposals":{"type":"array","items":{"type":"object",\
    "properties":{"key":{"type":"string"},"at":{"type":"string"},"minutes":{"type":"integer"},\
    "reason":{"type":"string"}},"required":["key","at","minutes","reason"]}}},"required":["proposals"]}
    """

    /// Plans the tickets around the busy slots; `now` is when the plan starts.
    public func plan(tickets: [Ticket], busy: [BusySlot], now: Date) async throws -> Plan {
        guard !tickets.isEmpty else { return Plan(proposals: [], rejected: []) }
        let output = try await runner.output(config.resolvedClaudePath, [
            "-p", request(tickets: tickets, busy: busy, now: now),
            "--output-format", "json",
            "--json-schema", Self.schema,
            "--model", config.planModel,
            "--system-prompt", Self.systemPrompt,
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "",
            "--disable-slash-commands",
            "--no-session-persistence",
        ])
        return try validate(Self.parse(output), tickets: tickets, busy: busy, now: now)
    }

    /// The request: the context as JSON, so nothing in a ticket title reads as an instruction.
    func request(tickets: [Ticket], busy: [BusySlot], now: Date) -> String {
        let context: [String: Any] = [
            "now": localMinute(now, timeZone: timeZone),
            "workingHours": ["start": config.workdayStart, "end": config.workdayEnd, "days": "Monday to Friday"],
            "horizonDays": config.planDays,
            "busy": busy.map { ["start": localMinute($0.start, timeZone: timeZone), "end": localMinute($0.end, timeZone: timeZone), "title": $0.title] },
            "tickets": tickets.map { ["key": $0.key, "summary": $0.summary, "priority": $0.priority, "status": $0.status] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])) ?? Data()
        return "Schedule these tickets. Context:\n" + String(decoding: data, as: UTF8.self)
    }

    struct Answer: Decodable {
        struct Output: Decodable {
            struct Item: Decodable {
                let key: String
                let at: String
                let minutes: Int
                let reason: String
            }
            let proposals: [Item]
        }
        let is_error: Bool?
        let result: String?
        let structured_output: Output?
    }

    static func parse(_ json: String) throws -> [Answer.Output.Item] {
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        } catch {
            throw ShellError("unreadable answer from claude: \(json.prefix(160))")
        }
        if answer.is_error == true { throw ShellError("claude: \(answer.result ?? "error")") }
        guard let output = answer.structured_output else {
            throw ShellError("claude gave no structured answer: \((answer.result ?? "").prefix(160))")
        }
        return output.proposals
    }

    /// Keeps the proposals that name a ticket asked for, start in the future inside working
    /// hours on a weekday within the horizon, and overlap neither a busy slot nor each other.
    func validate(_ items: [Answer.Output.Item], tickets: [Ticket], busy: [BusySlot], now: Date) -> Plan {
        let byKey = Dictionary(tickets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let horizon = calendar.date(byAdding: .day, value: config.planDays + 1, to: calendar.startOfDay(for: now)) ?? now
        var taken = busy.map { ($0.start, $0.end) }
        var proposals: [PlanProposal] = []
        var rejected: [String] = []

        for item in items {
            guard let ticket = byKey[item.key], !proposals.contains(where: { $0.key == item.key }) else {
                rejected.append("\(item.key) : ticket non demandé")
                continue
            }
            let at = item.at.replacingOccurrences(of: "T", with: " ").prefix(16)
            guard let start = parseLocalMinute(String(at), timeZone: timeZone) else {
                rejected.append("\(item.key) : heure illisible (\(item.at))")
                continue
            }
            let minutes = min(max(item.minutes, 15), 240)
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))
            let weekday = calendar.component(.weekday, from: start)
            let startClock = String(localMinute(start, timeZone: timeZone).suffix(5))
            let endClock = String(localMinute(end, timeZone: timeZone).suffix(5))
            if start <= now || start >= horizon {
                rejected.append("\(item.key) : hors de la période (\(at))")
            } else if weekday == 1 || weekday == 7 {
                rejected.append("\(item.key) : tombe un week-end (\(at))")
            } else if startClock < config.workdayStart || endClock > config.workdayEnd || !calendar.isDate(start, inSameDayAs: end) {
                rejected.append("\(item.key) : hors des heures de travail (\(at))")
            } else if let clash = taken.first(where: { $0.0 < end && start < $0.1 }) {
                rejected.append("\(item.key) : chevauche un créneau occupé à \(localMinute(clash.0, timeZone: timeZone).suffix(5))")
            } else {
                taken.append((start, end))
                proposals.append(PlanProposal(key: item.key, summary: ticket.summary, at: String(at), minutes: minutes, reason: item.reason))
            }
        }
        return Plan(proposals: proposals.sorted { $0.at < $1.at }, rejected: rejected)
    }
}

/// The date of a local "YYYY-MM-DD HH:MM".
public func parseLocalMinute(_ text: String, timeZone: TimeZone = .current) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)
}
