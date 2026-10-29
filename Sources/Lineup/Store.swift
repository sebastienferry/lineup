import AppKit
import LineupCore
import Foundation

/// The app's state: what it read last, and every action, each followed by a refresh.
@MainActor
final class Store: ObservableObject {
    enum View: String, CaseIterable { case list = "Liste", agenda = "Agenda", inbox = "Notifs" }

    @Published var view: View = .list
    @Published private(set) var tickets: [Ticket] = []
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var canChangePriority = false
    /// The ticket keys and event ids an action is running on, drawn dimmed until it finishes.
    @Published private(set) var busy: Set<String> = []
    /// A one-line report of the last action, cleared after a few seconds.
    @Published private(set) var notice: String?
    /// The slots Claude proposed, waiting for the user to apply or dismiss them.
    @Published var plan: Plan?
    /// The search query; empty shows everything.
    @Published var query = ""
    /// The keys pinned by hand; their open tickets join the list.
    @Published private(set) var pinned: [String] = TicketKeyList.pinned.keys()
    /// The keys hidden by hand; their tickets leave the list and are never planned.
    @Published private(set) var hidden: [String] = TicketKeyList.hidden.keys()
    @Published private(set) var isPlanning = false
    /// The notifications of the inbox, newest first, reloaded as soon as the file changes.
    @Published private(set) var inboxItems: [InboxItem] = []

    private(set) var config = Config.load()
    private let calendar = CalendarClient()
    private let inbox = Inbox()
    private var inboxModifiedAt: Date?
    private var timer: Timer?
    private var inboxTimer: Timer?

    var jira: JiraClient { JiraClient(config: config) }
    var backlog: Backlog { Backlog(tickets: tickets, events: upcoming, projects: projects, hiddenKeys: Set(hidden)) }
    /// Upcoming events over the planning horizon: the agenda shows the first days, the backlog
    /// links tickets to their blocks across all of them.
    @Published private(set) var upcoming: [AgendaEvent] = []
    /// The calendars a plan can be written to, and the one chosen, remembered by the app.
    @Published private(set) var writableCalendars: [CalendarClient.WritableCalendar] = []
    // Read from the preferences Lineup kept when it was called BacklogBar until chosen again.
    @Published var planCalendarId: String = UserDefaults.standard.string(forKey: "planCalendarId")
        ?? UserDefaults(suiteName: "io.github.sebferry.backlogbar")?.string(forKey: "planCalendarId") ?? "" {
        didSet { UserDefaults.standard.set(planCalendarId, forKey: "planCalendarId") }
    }
    /// The projects ticket keys are recognised in: the configured ones and those of pinned keys.
    var projects: [String] {
        var projects = config.knownProjects
        for key in pinned {
            if let project = key.split(separator: "-").first.map(String.init), !projects.contains(project) { projects.append(project) }
        }
        return projects
    }
    /// The backlog the views draw: the search applied.
    var visibleBacklog: Backlog { backlog.filtered(by: query) }
    var visibleEvents: [AgendaEvent] {
        let words = searchWords(query)
        return words.isEmpty ? events : events.filter { matchesAll(words, in: [$0.title]) }
    }
    var visibleInbox: [InboxItem] {
        let words = searchWords(query)
        return words.isEmpty ? inboxItems : inboxItems.filter { $0.matches(words) }
    }
    var unreadCount: Int { inboxItems.filter { !$0.isRead }.count }

    func start() {
        // The menu bar label's task can run again when the label redraws; start once.
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(config.refreshMinutes, 1) * 60), repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // Other processes post to the inbox at any time; checking its date every two seconds
        // costs one stat and shows a notification right away.
        reloadInbox()
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadInbox() }
        }
    }

    private func reloadInbox(force: Bool = false) {
        let modifiedAt = inbox.modifiedAt()
        guard force || modifiedAt != inboxModifiedAt else { return }
        inboxModifiedAt = modifiedAt
        inboxItems = inbox.items()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        config = Config.load()
        var errors: [String] = []

        pinned = TicketKeyList.pinned.keys()
        hidden = TicketKeyList.hidden.keys()
        let pinnedKeys = pinned
        async let ticketsResult = capture { () -> [Ticket] in
            let found = try await self.jira.search()
            let extra = try await self.jira.openTickets(keys: pinnedKeys.filter { key in !found.contains { $0.key == key } })
            return found + extra
        }
        let (fetchedTickets, ticketsError) = await ticketsResult
        if let fetchedTickets { tickets = fetchedTickets }
        if let ticketsError { errors.append("Jira : \(ticketsError)") }

        if await calendar.requestAccess() {
            upcoming = calendar.events(days: max(config.agendaDays, config.planDays))
            let agendaEnd = Calendar.current.date(byAdding: .day, value: max(config.agendaDays, 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
            events = upcoming.filter { $0.start < agendaEnd }
            writableCalendars = calendar.writableCalendars()
            if !writableCalendars.contains(where: { $0.id == planCalendarId }) {
                planCalendarId = writableCalendars.first?.id ?? ""
            }
        } else {
            errors.append("Agenda : accès au calendrier refusé (Réglages Système › Confidentialité › Calendriers)")
        }
        canChangePriority = jira.canChangePriority
        self.errors = errors
        updatedAt = Date()
    }

    // MARK: Actions

    func closeTicket(_ ticket: Ticket) {
        perform(on: ticket.key, done: "✅ \(ticket.key) passé en \(config.doneStatus)") {
            try await self.jira.close(key: ticket.key)
        }
    }

    func step(_ ticket: Ticket, by step: Int) {
        guard let target = steppedPriority(ticket.priority, by: step) else { return }
        perform(on: ticket.key, done: "\(ticket.key) : \(ticket.priority) → \(target)") {
            try await self.jira.setPriority(key: ticket.key, priority: target)
        }
    }

    /// A quick add: a ticket in the project, and a block in the calendar when "@" named a time.
    func add(_ input: String, to project: String) async -> Bool {
        guard let task = parseQuickTask(input, now: localMinute(Date())) else {
            show("Rien à ajouter : le titre est vide")
            return false
        }
        do {
            let key = try await jira.create(project: project, summary: task.title)
            if task.isScheduled, let start = parseLocalMinute(task.at) {
                _ = try calendar.addEvent(
                    title: "\(key) \(task.title)",
                    start: start,
                    minutes: 60,
                    calendarId: planCalendarId,
                    url: config.browseURL(for: key),
                    notes: nil
                )
            }
            show("🎫 \(key) créé\(task.isScheduled ? " et bloqué \(task.at.dropFirst(5))" : "")")
            await refresh()
            return true
        } catch {
            show("⚠ Rien ajouté : \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Planning

    /// Plans the unscheduled tickets, highest priority first, up to `maxPlanned`.
    func planAll() {
        runPlan(Array(backlog.unscheduled.prefix(max(config.maxPlanned, 1))))
    }

    func plan(only ticket: Ticket) {
        runPlan([ticket])
    }

    private func runPlan(_ tickets: [Ticket]) {
        guard !tickets.isEmpty, !isPlanning else { return }
        isPlanning = true
        plan = nil
        let now = Date()
        let busy = calendar.events(days: config.planDays, now: now)
            .filter { !$0.isAllDay }
            .map { BusySlot(start: $0.start, end: $0.end, title: $0.title) }
        let planner = Planner(config: config)
        Task {
            do {
                plan = try await planner.plan(tickets: tickets, busy: busy, now: now)
                if plan?.proposals.isEmpty == true { show("Claude n’a trouvé aucun créneau libre") }
            } catch {
                show("⚠ Planification impossible : \(error.localizedDescription)")
            }
            isPlanning = false
        }
    }

    /// Writes the chosen proposals as events of their duration in the chosen calendar, titled
    /// with the ticket key, so the list files the ticket under "Dans l'agenda".
    func apply(_ proposals: [PlanProposal]) {
        let calendarId = planCalendarId
        plan = nil
        var failures: [String] = []
        for proposal in proposals {
            guard let start = parseLocalMinute(proposal.at) else {
                failures.append(proposal.key)
                continue
            }
            do {
                _ = try calendar.addEvent(
                    title: "\(proposal.key) \(proposal.summary)",
                    start: start,
                    minutes: proposal.minutes,
                    calendarId: calendarId,
                    url: config.browseURL(for: proposal.key),
                    notes: proposal.reason
                )
            } catch {
                failures.append("\(proposal.key) (\(error.localizedDescription))")
            }
        }
        show(failures.isEmpty ? "📅 \(proposals.count) bloc(s) ajouté(s) à l’agenda" : "⚠ Non planifiés : \(failures.joined(separator: ", "))")
        Task { await refresh() }
    }

    /// Removes a ticket's block from the calendar; the ticket goes back to "À planifier".
    func unblock(_ item: Backlog.Blocked) {
        perform(on: item.event.id, done: "\(item.ticket.key) retiré de l’agenda") {
            try self.calendar.removeEvent(id: item.event.id)
        }
    }

    // MARK: Inbox

    func markRead(_ item: InboxItem) {
        changeInbox { try self.inbox.markRead(ids: [item.id]) }
    }

    func markAllRead() {
        changeInbox { try self.inbox.markRead(ids: nil) }
    }

    func dismiss(_ item: InboxItem) {
        changeInbox { try self.inbox.dismiss(ids: [item.id]) }
    }

    func dismissRead() {
        changeInbox { try self.inbox.dismiss(ids: nil) }
    }

    /// Opens the notification's link and marks it read.
    func open(_ item: InboxItem) {
        if let link = item.url, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        markRead(item)
    }

    private func changeInbox(_ work: () throws -> Int) {
        do {
            _ = try work()
        } catch {
            show("⚠ \(error.localizedDescription)")
        }
        reloadInbox(force: true)
    }

    // MARK: Pins

    /// Pins a ticket of any project, once Jira confirms it exists.
    func pin(_ key: String) {
        perform(on: key, done: "📌 \(key) épinglé") {
            let ticket = try await self.jira.ticket(key: key)
            try TicketKeyList.pinned.add(ticket.key)
            self.query = ""
        }
    }

    func unpin(_ key: String) {
        perform(on: key, done: "\(key) retiré de la liste") {
            try TicketKeyList.pinned.remove(key)
        }
    }

    /// Takes a ticket out of the list and out of planning, until it is shown again.
    func hide(_ key: String) {
        perform(on: key, done: "🙈 \(key) masqué") {
            try TicketKeyList.hidden.add(key)
        }
    }

    func unhide(_ key: String) {
        perform(on: key, done: "\(key) de nouveau dans la liste") {
            try TicketKeyList.hidden.remove(key)
        }
    }

    func open(_ key: String) {
        if let url = config.browseURL(for: key) { NSWorkspace.shared.open(url) }
    }

    func openConfig() {
        _ = Config.load()
        NSWorkspace.shared.open(Config.fileURL)
    }

    // MARK: Setup

    let version = appVersion()
    /// Whether Claude Code runs this app's inbox server; nil until checked.
    @Published private(set) var isMCPInstalled: Bool?
    @Published private(set) var isInstallingMCP = false

    private var mcpSetup: MCPSetup { MCPSetup(claudePath: config.resolvedClaudePath) }

    func checkMCP() {
        Task { isMCPInstalled = await mcpSetup.isInstalled(command: notifyExecutablePath()) }
    }

    /// Registers the inbox server with Claude Code, for every project.
    func installMCP() {
        guard !isInstallingMCP else { return }
        isInstallingMCP = true
        Task {
            do {
                try await mcpSetup.install(command: notifyExecutablePath())
                show("🔌 Serveur MCP « \(MCPSetup.serverName) » installé dans Claude Code")
            } catch {
                show("⚠ Installation du MCP impossible : \(error.localizedDescription)")
            }
            isMCPInstalled = await mcpSetup.isInstalled(command: notifyExecutablePath())
            isInstallingMCP = false
        }
    }

    // MARK: Plumbing

    private func perform(on id: String, done message: String, _ work: @escaping () async throws -> Void) {
        busy.insert(id)
        Task {
            do {
                try await work()
                show(message)
            } catch {
                show("⚠ \(error.localizedDescription)")
            }
            busy.remove(id)
            await refresh()
        }
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == message { notice = nil }
        }
    }

    private func capture<T>(_ work: @escaping () async throws -> T) async -> (T?, String?) {
        do { return (try await work(), nil) } catch { return (nil, error.localizedDescription) }
    }
}
