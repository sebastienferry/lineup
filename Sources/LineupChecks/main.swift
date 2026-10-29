import LineupCore
import Foundation

// The checks of LineupCore. Each `check` prints its outcome; the run exits 1 when one fails.

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        print("✓ \(name)")
    } catch {
        failures += 1
        print("✗ \(name): \(error)")
    }
}

struct Mismatch: Error, CustomStringConvertible {
    let description: String
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ line: Int = #line) throws {
    guard actual == expected else { throw Mismatch(description: "line \(line): got \(actual), expected \(expected)") }
}

/// Canned command output, keyed by the subcommand, recording every call.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    var outputs: [String: ShellResult] = [:]
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) async throws -> ShellResult {
        calls.append(arguments)
        let subcommand = arguments.first == "jira" ? arguments.dropFirst(2).first ?? "" : arguments.first ?? ""
        return outputs[subcommand] ?? ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

func ticket(_ key: String, _ priority: String) -> Ticket {
    Ticket(key: key, summary: "Summary \(key)", priority: priority, status: "To Do", created: nil)
}

// MARK: Quick add

await check("\"@ demain 10h\" is tomorrow 10:00, scheduled") {
    try expect(
        parseQuickTask("Relancer Yann sur PE-2469 @ demain 10h", now: "2026-10-12 12:05"),
        QuickTask(title: "Relancer Yann sur PE-2469", at: "2026-10-13 10:00", isScheduled: true)
    )
}
await check("an explicit date keeps its minutes") {
    try expect(parseQuickTask("Review @ 2026-10-22 09:15", now: "2026-10-12 12:05")?.at, "2026-10-22 09:15")
}
await check("a time alone is today") {
    try expect(parseQuickTask("Call @ 16h30", now: "2026-10-12 12:05")?.at, "2026-10-12 16:30")
}
await check("no time is the next full hour, not scheduled") {
    try expect(parseQuickTask("Lire la spec", now: "2026-10-12 12:05"), QuickTask(title: "Lire la spec", at: "2026-10-12 13:00", isScheduled: false))
}
await check("no time after 18:00 is tomorrow 09:30") {
    try expect(parseQuickTask("Lire la spec", now: "2026-10-12 19:00")?.at, "2026-10-13 09:30")
}
await check("an empty title is refused") {
    try expect(parseQuickTask("  @ demain", now: "2026-10-12 12:05"), nil)
}
await check("adding a day crosses months") {
    try expect(addDays("2026-10-31", 1), "2026-11-01")
}

// MARK: Backlog

await check("the tickets without a block are sorted by priority") {
    let tickets = [ticket("SFE-1", "Low"), ticket("SFE-2", "Highest"), ticket("SFE-3", "Medium"), ticket("SFE-4", "High")]
    let backlog = Backlog(tickets: tickets, projects: ["SFE", "PE"])
    try expect(backlog.unscheduled.map(\.key), ["SFE-2", "SFE-4", "SFE-3", "SFE-1"])
    try expect(backlog.blocked.isEmpty, true)
}
await check("priority steps stop at both ends") {
    try expect(steppedPriority("Medium", by: -1), "High")
    try expect(steppedPriority("Highest", by: -1), nil)
    try expect(steppedPriority("Lowest", by: 1), nil)
}
await check("ticket keys need a word boundary") {
    try expect(firstTicketKey(in: "XSFE-12", projects: ["SFE"]), nil)
    try expect(firstTicketKey(in: "see SFE-12, then PE-3", projects: ["SFE", "PE"]), "SFE-12")
}

await check("the search matches every word, ignoring case and accents") {
    let tickets = [
        Ticket(key: "SFE-1", summary: "Préparer la rétro", priority: "High", status: "To Do", created: nil),
        Ticket(key: "SFE-2", summary: "Rotate the token", priority: "Low", status: "In Progress", created: nil),
        Ticket(key: "SFE-3", summary: "Kickoff ThinkOn", priority: "Medium", status: "To Do", created: nil),
    ]
    let block = AgendaEvent(
        id: "e", title: "SFE-3 lire l'agenda", start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(7200), isAllDay: false, meetURL: nil
    )
    let backlog = Backlog(tickets: tickets, events: [block], projects: ["SFE"])
    try expect(backlog.filtered(by: "RETRO prep").unscheduled.map(\.key), ["SFE-1"])
    try expect(backlog.filtered(by: "progress").unscheduled.map(\.key), ["SFE-2"])
    // A block matches through the ticket it names.
    try expect(backlog.filtered(by: "thinkon").blocked.map(\.ticket.key), ["SFE-3"])
    try expect(backlog.filtered(by: "  ").unscheduled.count, 2)
}

await check("the legacy priority scheme sorts with the default one and steps within itself") {
    let mixed = [ticket("PE-1", "Minor"), ticket("SFE-1", "Highest"), ticket("PE-2", "Critical"), ticket("SFE-2", "Medium"), ticket("PE-3", "Major")]
    try expect(sortedByPriority(mixed).map(\.key), ["SFE-1", "PE-2", "SFE-2", "PE-3", "PE-1"])
    try expect(steppedPriority("Major", by: -1), "Critical")
    try expect(steppedPriority("Blocker", by: -1), nil)
}
await check("a key typed in the search reads as a ticket key") {
    try expect(ticketKey(fromQuery: " pe-2469 "), "PE-2469")
    try expect(ticketKey(fromQuery: "PE 2469"), nil)
    try expect(ticketKey(fromQuery: "rotate token"), nil)
}
await check("pinned keys are saved once and removed") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-pinned-\(UUID().uuidString).json")
    let pins = TicketKeyList(url: url)
    try pins.add("PE-1")
    try pins.add("PE-1")
    try pins.add("OPS-7")
    try expect(pins.keys(), ["PE-1", "OPS-7"])
    try pins.remove("PE-1")
    try expect(pins.keys(), ["OPS-7"])
    try? FileManager.default.removeItem(at: url)
}
await check("pinned tickets are fetched open only, in one query") {
    let runner = FakeRunner()
    runner.outputs["search"] = ShellResult(exitCode: 0, stdout: "[]", stderr: "")
    _ = try await JiraClient(config: .defaults, runner: runner).openTickets(keys: ["PE-1", "OPS-7"])
    let call = runner.calls.first ?? []
    let jql = call.firstIndex(of: "--jql").map { call[$0 + 1] } ?? ""
    try expect(jql, "key in (PE-1, OPS-7) AND statusCategory != Done")
}

await check("a hidden ticket leaves both parts of the list, its block included") {
    let block = AgendaEvent(
        id: "e", title: "SFE-2 Rotate", start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(7200), isAllDay: false, meetURL: nil
    )
    let tickets = [ticket("SFE-1", "High"), ticket("SFE-2", "Low"), ticket("SFE-3", "Medium")]
    let backlog = Backlog(tickets: tickets, events: [block], projects: ["SFE"], hiddenKeys: ["SFE-2", "SFE-3"])
    try expect(backlog.unscheduled.map(\.key), ["SFE-1"])
    try expect(backlog.blocked.isEmpty, true)
    try expect(backlog.hidden.map(\.key), ["SFE-3", "SFE-2"])
    // The search still finds a hidden ticket, in its own part.
    try expect(backlog.filtered(by: "summary sfe-2").hidden.map(\.key), ["SFE-2"])
}
await check("a calendar block naming an open ticket takes it out of the unscheduled ones") {
    let now = parseLocalMinute("2026-10-20 08:00")!
    func event(_ title: String, _ start: String, _ end: String) -> AgendaEvent {
        AgendaEvent(id: title, title: title, start: parseLocalMinute(start)!, end: parseLocalMinute(end)!, isAllDay: false, meetURL: nil)
    }
    let events = [
        event("SFE-2 Rotate the token", "2026-10-21 10:00", "2026-10-21 11:00"),
        event("SFE-3 Past block", "2026-10-19 10:00", "2026-10-19 11:00"),   // over: the ticket is unscheduled again
        event("Weekly sync", "2026-10-20 14:00", "2026-10-20 15:00"),        // names no ticket
    ]
    let backlog = Backlog(tickets: [ticket("SFE-1", "High"), ticket("SFE-2", "Low"), ticket("SFE-3", "Medium")], events: events, projects: ["SFE"], now: now)
    try expect(backlog.blocked.map(\.ticket.key), ["SFE-2"])
    try expect(backlog.unscheduled.map(\.key), ["SFE-1", "SFE-3"])
}

// MARK: Config

await check("missing keys take their defaults") {
    let config = try JSONDecoder().decode(Config.self, from: Data(#"{"createProjects": ["SFE", "PE"]}"#.utf8))
    try expect(config.createProjects, ["SFE", "PE"])
    try expect(config.issueType, "Task")
    try expect(config.agendaDays, 3)
}
await check("known projects include the ones the JQL names") {
    var config = Config.defaults
    config.createProjects = ["PE"]
    config.jql = "project = SFE AND statusCategory != Done"
    try expect(config.knownProjects, ["PE", "SFE"])
    config.jql = "project in (ABC, \"DEF\") ORDER BY priority"
    try expect(config.knownProjects, ["PE", "ABC", "DEF"])
}

// MARK: Clients

await check("Jira search reads acli's JSON") {
    let runner = FakeRunner()
    // The shape acli prints, trimmed to what the client reads.
    runner.outputs["search"] = ShellResult(exitCode: 0, stdout: """
    [{"key": "SFE-415", "id": "1", "fields": {"summary": "Kickoff", "priority": {"name": "Highest"}, "status": {"name": "To Do"}}},
     {"key": "SFE-12", "id": "2", "fields": {"summary": "No priority", "status": {"name": "In Progress"}}}]
    """, stderr: "")
    let tickets = try await JiraClient(config: .defaults, runner: runner).search()
    try expect(tickets.map(\.key), ["SFE-415", "SFE-12"])
    try expect(tickets.map(\.priority), ["Highest", "Medium"])
    try expect(Array(runner.calls.first?.prefix(3) ?? []), ["jira", "workitem", "search"])
}
await check("Jira create answers the new key") {
    let runner = FakeRunner()
    runner.outputs["create"] = ShellResult(exitCode: 0, stdout: #"{"key": "PE-9001", "id": "77"}"#, stderr: "")
    let key = try await JiraClient(config: .defaults, runner: runner).create(project: "PE", summary: "Rotate the token")
    try expect(key, "PE-9001")
    try expect(runner.calls.first ?? [], ["jira", "workitem", "create", "--project", "PE", "--type", "Task", "--summary", "Rotate the token", "--json"])
}
await check("a failing tool reports what it said") {
    let runner = FakeRunner()
    runner.outputs["search"] = ShellResult(exitCode: 1, stdout: "", stderr: "✗ Error: field 'created' is not allowed")
    do {
        _ = try await JiraClient(config: .defaults, runner: runner).search()
        throw Mismatch(description: "expected an error")
    } catch let error as ShellError {
        try expect(error.message.contains("is not allowed"), true)
    }
}
// MARK: Planner

let paris = TimeZone(identifier: "Europe/Paris")!
// Monday 2026-10-19 08:00 in Paris.
let monday = parseLocalMinute("2026-10-19 08:00", timeZone: paris)!

func planAnswer(_ items: [(String, String, Int)]) -> ShellResult {
    let proposals = items.map { #"{"key":"\#($0.0)","at":"\#($0.1)","minutes":\#($0.2),"reason":"ok"}"# }.joined(separator: ",")
    return ShellResult(exitCode: 0, stdout: #"{"is_error":false,"result":"","structured_output":{"proposals":[\#(proposals)]}}"#, stderr: "")
}

await check("the planner keeps valid slots and says why it drops the others") {
    let runner = FakeRunner()
    runner.outputs["-p"] = planAnswer([
        ("SFE-1", "2026-10-19 10:00", 60),   // fine
        ("SFE-2", "2026-10-19 10:30", 30),   // overlaps SFE-1
        ("SFE-3", "2026-10-19 14:00", 60),   // overlaps the meeting
        ("SFE-4", "2026-10-24 10:00", 60),   // a Saturday
        ("SFE-5", "2026-10-19 18:00", 60),   // ends after 18:30
        ("XYZ-9", "2026-10-20 10:00", 60),   // not asked for
        ("SFE-6", "2026-10-20T09:00:00", 45), // ISO form is accepted
    ])
    let tickets = (1...6).map { ticket("SFE-\($0)", "High") }
    let meeting = BusySlot(start: parseLocalMinute("2026-10-19 13:30", timeZone: paris)!, end: parseLocalMinute("2026-10-19 15:00", timeZone: paris)!, title: "Weekly")
    let plan = try await Planner(config: .defaults, runner: runner, timeZone: paris).plan(tickets: tickets, busy: [meeting], now: monday)
    try expect(plan.proposals.map(\.key), ["SFE-1", "SFE-6"])
    try expect(plan.proposals.map(\.at), ["2026-10-19 10:00", "2026-10-20 09:00"])
    try expect(plan.rejected.count, 5)
    // Claude gets no tools and our own system prompt.
    let call = runner.calls.first ?? []
    try expect(call.contains("--tools") && call.contains("--system-prompt") && call.contains("--json-schema"), true)
}
await check("a claude error is reported") {
    let runner = FakeRunner()
    runner.outputs["-p"] = ShellResult(exitCode: 0, stdout: #"{"is_error":true,"result":"Not logged in"}"#, stderr: "")
    do {
        _ = try await Planner(config: .defaults, runner: runner, timeZone: paris).plan(tickets: [ticket("SFE-1", "High")], busy: [], now: monday)
        throw Mismatch(description: "expected an error")
    } catch let error as ShellError {
        try expect(error.message.contains("Not logged in"), true)
    }
}

// MARK: Inbox

func scratchInbox() -> Inbox {
    Inbox(url: FileManager.default.temporaryDirectory.appendingPathComponent("lineup-checks-\(UUID().uuidString)/inbox.json"))
}

await check("posted notifications list newest first, unread") {
    let inbox = scratchInbox()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    try inbox.post(source: "ci", title: "Build red", level: .error, now: t0)
    try inbox.post(source: "claude", title: "Done", now: t0.addingTimeInterval(60))
    try expect(inbox.items().map(\.title), ["Done", "Build red"])
    try expect(inbox.items().map(\.isRead), [false, false])
}
await check("a posting with the same source and key replaces the earlier one") {
    let inbox = scratchInbox()
    let first = try inbox.post(source: "ci", title: "Build red", key: "main")
    try inbox.markRead(ids: [first.id])
    try inbox.post(source: "ci", title: "Build green", key: "main")
    try inbox.post(source: "other", title: "Unrelated", key: "main")
    try expect(inbox.items().map(\.title), ["Unrelated", "Build green"])
    try expect(inbox.items().contains(where: \.isRead), false)
}
await check("mark read, then dismiss the read ones") {
    let inbox = scratchInbox()
    let a = try inbox.post(source: "x", title: "A")
    try inbox.post(source: "x", title: "B")
    try expect(try inbox.markRead(ids: [a.id]), 1)
    try expect(try inbox.dismiss(ids: nil), 1)
    try expect(inbox.items().map(\.title), ["B"])
    try expect(try inbox.markRead(ids: nil), 1)
}
await check("read notifications older than the retention go") {
    let inbox = scratchInbox()
    let old = Date(timeIntervalSince1970: 1_800_000_000)
    try inbox.post(source: "x", title: "Old", now: old)
    try inbox.markRead(ids: nil, now: old)
    try inbox.post(source: "x", title: "New", now: old.addingTimeInterval(Double(Inbox.keepReadDays + 1) * 86_400))
    try expect(inbox.items().map(\.title), ["New"])
}
await check("an empty title is refused") {
    do {
        try scratchInbox().post(source: "x", title: "  ")
        throw Mismatch(description: "expected an error")
    } catch is ShellError {}
}

// MARK: MCP

func reply(_ server: InboxMCP, _ line: String) throws -> [String: Any] {
    guard let text = server.handle(line), let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw Mismatch(description: "no JSON reply to \(line)")
    }
    return json
}

func toolText(_ json: [String: Any]) -> String {
    let content = (json["result"] as? [String: Any])?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String ?? ""
}

await check("mcp: initialize answers the client's protocol version and the tools capability") {
    let json = try reply(InboxMCP(inbox: scratchInbox()), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    let result = json["result"] as? [String: Any] ?? [:]
    try expect(result["protocolVersion"] as? String, "2025-06-18")
    try expect((result["capabilities"] as? [String: Any])?["tools"] != nil, true)
}
await check("mcp: a notification gets no reply, an unknown method an error") {
    let server = InboxMCP(inbox: scratchInbox())
    try expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), nil)
    try expect(((try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"nope"}"#))["error"] as? [String: Any])?["code"] as? Int, -32601)
}
await check("mcp: tools/list names the four tools") {
    let json = try reply(InboxMCP(inbox: scratchInbox()), #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
    let tools = (json["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    try expect(tools.compactMap { $0["name"] as? String }, ["list_notifications", "post_notification", "mark_read", "dismiss_notifications"])
}
await check("mcp: post, list unread, mark read, list again") {
    let inbox = scratchInbox()
    let server = InboxMCP(inbox: inbox)
    _ = try reply(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"post_notification","arguments":{"title":"Deploy done","level":"success","url":"https://example.com/x"}}}"#)
    try expect(inbox.items().first?.source, "claude")
    try expect(inbox.items().first?.level, .success)
    let listed = toolText(try reply(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_notifications","arguments":{}}}"#))
    try expect(listed.contains("\"unread\":1") && listed.contains("https://example.com/x"), true)
    let id = inbox.items().first?.id ?? ""
    _ = try reply(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mark_read","arguments":{"ids":["\#(id)"]}}}"#)
    let after = toolText(try reply(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_notifications","arguments":{}}}"#))
    try expect(after.contains("\"unread\":0") && after.contains("\"notifications\":[]"), true)
}
await check("mcp: a bad call is a tool error, not a protocol error") {
    let json = try reply(InboxMCP(inbox: scratchInbox()), #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"mark_read","arguments":{}}}"#)
    try expect((json["result"] as? [String: Any])?["isError"] as? Bool, true)
}

// MARK: MCP setup

await check("setup: the registered command is read from claude mcp get") {
    let runner = FakeRunner()
    runner.outputs["mcp"] = ShellResult(exitCode: 0, stdout: """
        inbox:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
          Type: stdio
          Command: /Users/me/.local/bin/lineup-notify
          Args: mcp
        """, stderr: "")
    try expect(await MCPSetup(claudePath: "claude", runner: runner).registeredCommand(), "/Users/me/.local/bin/lineup-notify")
}
await check("setup: not registered when claude mcp get fails") {
    let runner = FakeRunner()
    runner.outputs["mcp"] = ShellResult(exitCode: 1, stdout: "", stderr: "No MCP server named \"inbox\"")
    try expect(await MCPSetup(claudePath: "claude", runner: runner).isInstalled(command: "/x/lineup-notify"), false)
}
await check("setup: install replaces the user-scope registration") {
    let runner = FakeRunner()
    try await MCPSetup(claudePath: "claude", runner: runner).install(command: "/x/lineup-notify")
    try expect(runner.calls, [
        ["mcp", "remove", "inbox", "-s", "user"],
        ["mcp", "add", "--scope", "user", "inbox", "--", "/x/lineup-notify", "mcp"],
    ])
}

// MARK: Live

// `swift run lineup-checks --live` asks the real claude, with made-up tickets.
if CommandLine.arguments.contains("--live") {
    await check("live: claude plans two tickets around a meeting") {
        let now = Date()
        let tomorrow10 = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(10 * 3600)
        let plan = try await Planner(config: .defaults).plan(
            tickets: [ticket("SFE-1", "Highest"), ticket("SFE-2", "Low")],
            busy: [BusySlot(start: tomorrow10, end: tomorrow10.addingTimeInterval(3600), title: "Meeting")],
            now: now
        )
        print("  proposals: \(plan.proposals.map { "\($0.key) \($0.at) \($0.minutes)min" })")
        print("  rejected: \(plan.rejected)")
        try expect(plan.proposals.isEmpty, false)
    }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
