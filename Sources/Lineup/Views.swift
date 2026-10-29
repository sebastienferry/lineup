import LineupCore
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var store: Store
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            Header(isAdding: $isAdding)
            SearchBar()
            if isAdding { AddBar(isAdding: $isAdding) }
            ForEach(store.errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
            if store.isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude planifie…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            Divider()
            ScrollView {
                if let plan = store.plan {
                    PlanContent(plan: plan)
                } else {
                    switch store.view {
                    case .list: ListContent()
                    case .agenda: AgendaContent()
                    case .inbox: InboxContent()
                    }
                }
            }
            Divider()
            Footer()
        }
    }
}

// MARK: Header and footer

struct Header: View {
    @EnvironmentObject var store: Store
    @Binding var isAdding: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $store.view) {
                ForEach(Store.View.allCases, id: \.self) { view in
                    let unread = store.unreadCount
                    Text(view == .inbox && unread > 0 ? "\(view.rawValue) \(unread)" : view.rawValue).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            let backlog = store.backlog
            Text("\(backlog.blocked.count) dans l’agenda · \(backlog.unscheduled.count) à planifier")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.planAll()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .help("Planifier les tickets à planifier avec Claude")
            .disabled(store.isPlanning || backlog.unscheduled.isEmpty)
            .keyboardShortcut("p")
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Rafraîchir")
            .keyboardShortcut("r")
            Button {
                isAdding.toggle()
            } label: {
                Image(systemName: isAdding ? "xmark.circle.fill" : "plus.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Créer un ticket")
            .keyboardShortcut("n")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct Footer: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack {
            if let notice = store.notice {
                Text(notice).font(.caption).lineLimit(1)
            } else if let updatedAt = store.updatedAt {
                Text("Mis à jour à \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // The button menu style draws its label like the borderless buttons beside it; the
            // borderless one ignores the caption font and draws a full-size control.
            Menu {
                Text("Lineup \(store.version)")
                Divider()
                Button("Ouvrir les réglages…") { store.openConfig() }
                Button(mcpLabel) { store.installMCP() }
                    .disabled(store.isInstallingMCP)
            } label: {
                Text("Réglages").font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .onAppear { store.checkMCP() }
            Button("Quitter") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var mcpLabel: String {
        if store.isInstallingMCP { return "Installation du serveur MCP…" }
        return store.isMCPInstalled == true
            ? "✓ Serveur MCP installé dans Claude Code (réinstaller)"
            : "Installer le serveur MCP dans Claude Code"
    }
}

// MARK: Search

struct SearchBar: View {
    @EnvironmentObject var store: Store
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher un ticket ou une réunion", text: $store.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { store.query = "" }
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Effacer")
            }
            // ⌘F puts the cursor in the field.
            Button("") { isFocused = true }
                .keyboardShortcut("f")
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: Quick add

struct AddBar: View {
    @EnvironmentObject var store: Store
    @Binding var isAdding: Bool
    @State private var project = ""
    @State private var text = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.config.createProjects.isEmpty {
                Text("Ajoute des projets dans « createProjects » (Réglages) pour créer des tickets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $project) {
                    ForEach(store.config.createProjects, id: \.self) { project in
                        Text("Ticket \(project)").tag(project)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    TextField("Titre du ticket \(project)", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onSubmit(submit)
                        .disabled(isSubmitting)
                    Button("Créer", action: submit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
                Text("Ajoute « @ 14h », « @ demain 10h » ou « @ 2026-10-22 09:00 » pour bloquer une heure dans l’agenda.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onAppear {
            if !store.config.createProjects.contains(project) { project = store.config.createProjects.first ?? "" }
            isFocused = true
        }
    }

    private func submit() {
        let input = text
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty, !project.isEmpty else { return }
        isSubmitting = true
        Task {
            if await store.add(input, to: project) {
                text = ""
                isAdding = false
            }
            isSubmitting = false
        }
    }
}

// MARK: List

struct ListContent: View {
    @EnvironmentObject var store: Store
    @State private var showsHidden = false

    var body: some View {
        let backlog = store.visibleBacklog
        LazyVStack(alignment: .leading, spacing: 0) {
            if store.updatedAt == nil {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
            if let key = ticketKey(fromQuery: store.query),
               !store.tickets.contains(where: { $0.key == key }), !store.pinned.contains(key) {
                Button {
                    store.pin(key)
                } label: {
                    Label("Épingler \(key) dans la liste", systemImage: "pin")
                }
                .buttonStyle(.borderless)
                .disabled(store.busy.contains(key))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            if !backlog.blocked.isEmpty {
                SectionTitle(text: "Dans l’agenda", count: backlog.blocked.count)
                ForEach(backlog.blocked) { item in
                    BlockedRow(item: item)
                }
            }
            SectionTitle(text: "À planifier", count: backlog.unscheduled.count)
            if backlog.unscheduled.isEmpty && store.updatedAt != nil {
                EmptyLine(text: "Tous les tickets sont planifiés.")
            }
            ForEach(backlog.unscheduled) { ticket in
                TicketRow(ticket: ticket)
            }
            if !backlog.hidden.isEmpty {
                // Folded by default: hidden tickets are out of the way until asked for.
                Button {
                    showsHidden.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsHidden ? "chevron.down" : "chevron.right").font(.caption2)
                        SectionTitle(text: "Masqués", count: backlog.hidden.count).padding(.horizontal, -12)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                if showsHidden {
                    ForEach(backlog.hidden) { ticket in
                        HiddenRow(ticket: ticket)
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }
}

struct SectionTitle: View {
    let text: String
    let count: Int

    var body: some View {
        HStack {
            Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// A ticket with no block in the calendar: check it off, move its priority, or plan it with Claude.
struct TicketRow: View {
    @EnvironmentObject var store: Store
    let ticket: Ticket
    @State private var isHovered = false

    var body: some View {
        Row(isHovered: $isHovered, isBusy: store.busy.contains(ticket.key)) {
            CheckButton(help: "Passer en \(store.config.doneStatus)") { store.closeTicket(ticket) }
            PriorityBadge(priority: ticket.priority)
            KeyLink(key: ticket.key)
            if store.pinned.contains(ticket.key) {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).help("Épinglé à la main")
            }
            Text(ticket.summary).lineLimit(1).truncationMode(.tail).help(ticket.summary)
            Spacer(minLength: 4)
            if isHovered {
                if store.pinned.contains(ticket.key) {
                    IconButton(symbol: "pin.slash", help: "Retirer de la liste") { store.unpin(ticket.key) }
                }
                if store.canChangePriority {
                    IconButton(symbol: "chevron.up", help: "Priorité plus haute", isEnabled: steppedPriority(ticket.priority, by: -1) != nil) {
                        store.step(ticket, by: -1)
                    }
                    IconButton(symbol: "chevron.down", help: "Priorité plus basse", isEnabled: steppedPriority(ticket.priority, by: 1) != nil) {
                        store.step(ticket, by: 1)
                    }
                }
                IconButton(symbol: "eye.slash", help: "Masquer : ni dans la liste, ni planifié") { store.hide(ticket.key) }
                IconButton(symbol: "wand.and.stars", help: "Trouver un créneau avec Claude", isEnabled: !store.isPlanning) {
                    store.plan(only: ticket)
                }
            } else if let created = ticket.created {
                Text(age(created)).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text(ticket.status).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

// MARK: Plan

/// Claude's proposals, each with a box to keep it, until applied or dismissed.
struct PlanContent: View {
    @EnvironmentObject var store: Store
    let plan: Plan
    @State private var excluded: Set<String> = []

    var body: some View {
        let chosen = plan.proposals.filter { !excluded.contains($0.key) }
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Proposition de Claude", count: plan.proposals.count)
            if plan.proposals.isEmpty {
                EmptyLine(text: "Aucun créneau proposé.")
            }
            HStack {
                Text("Ajouter à").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $store.planCalendarId) {
                    ForEach(store.writableCalendars) { calendar in
                        Text("\(calendar.title) · \(calendar.account)").tag(calendar.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            ForEach(plan.proposals) { proposal in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { !excluded.contains(proposal.key) },
                        set: { isOn in if isOn { excluded.remove(proposal.key) } else { excluded.insert(proposal.key) } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(dueLabel(proposal.at)).font(.callout.monospacedDigit()).frame(width: 86, alignment: .leading)
                            Text("\(proposal.minutes) min").font(.caption).foregroundStyle(.secondary)
                            KeyLink(key: proposal.key)
                            Text(proposal.summary).lineLimit(1).truncationMode(.tail)
                        }
                        Text(proposal.reason).font(.caption).foregroundStyle(.secondary).padding(.leading, 94)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            if !plan.rejected.isEmpty {
                SectionTitle(text: "Écartés", count: plan.rejected.count)
                ForEach(plan.rejected, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 1)
                }
            }
            HStack {
                Spacer()
                Button("Annuler") { store.plan = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Ajouter \(chosen.count) bloc(s) à l’agenda") { store.apply(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || store.planCalendarId.isEmpty)
            }
            .padding(12)
        }
    }
}

/// A ticket with time set aside in the calendar: close it, or take the block out.
struct BlockedRow: View {
    @EnvironmentObject var store: Store
    let item: Backlog.Blocked
    @State private var isHovered = false

    var body: some View {
        let ticket = item.ticket
        Row(isHovered: $isHovered, isBusy: store.busy.contains(ticket.key) || store.busy.contains(item.event.id)) {
            CheckButton(help: "Passer en \(store.config.doneStatus)") { store.closeTicket(ticket) }
            Text("\(dueLabel(localMinute(item.event.start)))-\(String(localMinute(item.event.end).suffix(5)))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 124, alignment: .leading)
            PriorityBadge(priority: ticket.priority)
            KeyLink(key: ticket.key)
            Text(ticket.summary).lineLimit(1).truncationMode(.tail).help(ticket.summary)
            Spacer(minLength: 4)
            if isHovered {
                IconButton(symbol: "eye.slash", help: "Masquer : ni dans la liste, ni planifié") { store.hide(ticket.key) }
                IconButton(symbol: "calendar.badge.minus", help: "Retirer le bloc de l’agenda") { store.unblock(item) }
            }
        }
    }
}

/// A hidden ticket, dimmed, with a button to bring it back to the list.
struct HiddenRow: View {
    @EnvironmentObject var store: Store
    let ticket: Ticket
    @State private var isHovered = false

    var body: some View {
        Row(isHovered: $isHovered, isBusy: store.busy.contains(ticket.key)) {
            PriorityBadge(priority: ticket.priority)
            KeyLink(key: ticket.key)
            Text(ticket.summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).help(ticket.summary)
            Spacer(minLength: 4)
            IconButton(symbol: "eye", help: "Réafficher dans la liste") { store.unhide(ticket.key) }
        }
    }
}

// MARK: Agenda

struct AgendaContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<max(store.config.agendaDays, 1)).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(days, id: \.self) { day in
                SectionTitle(text: dayLabel(day), count: 0).opacity(1)
                let events = store.visibleEvents.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
                if events.isEmpty {
                    EmptyLine(text: "Rien de prévu.")
                }
                ForEach(events) { event in
                    EventRow(event: event)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM"
        let name = formatter.string(from: day)
        if Calendar.current.isDateInToday(day) { return "Aujourd’hui · \(name)" }
        if Calendar.current.isDateInTomorrow(day) { return "Demain · \(name)" }
        return name
    }
}

struct EventRow: View {
    let event: AgendaEvent
    @State private var isHovered = false

    var body: some View {
        Row(isHovered: $isHovered, isBusy: false) {
            Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 18)
            Text(event.isAllDay ? "journée" : "\(time(event.start))-\(time(event.end))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(event.end < Date() ? .tertiary : .secondary)
                .frame(width: 86, alignment: .leading)
            Text(event.title).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(event.end < Date() ? .secondary : .primary)
            Spacer(minLength: 4)
            if let url = event.meetURL {
                Link(destination: url) { Image(systemName: "video.fill") }.help("Rejoindre")
            }
        }
    }

    private func time(_ date: Date) -> String { String(localMinute(date).suffix(5)) }
}

// MARK: Inbox

/// The notifications posted by scripts, hooks and Claude, newest first.
struct InboxContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let items = store.visibleInbox
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle(text: "Notifications", count: items.count)
                Spacer()
                Button("Tout marquer lu") { store.markAllRead() }
                    .disabled(store.unreadCount == 0)
                Button("Effacer les lues") { store.dismissRead() }
                    .disabled(!store.inboxItems.contains(where: \.isRead))
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.trailing, 12)
            if items.isEmpty {
                EmptyLine(text: "Aucune notification. Postez-en avec « lineup-notify post » ou l’outil MCP post_notification.")
            }
            ForEach(items) { item in
                InboxRow(item: item)
            }
        }
        .padding(.bottom, 8)
    }
}

/// A notification: open its link, mark it read, or dismiss it.
struct InboxRow: View {
    @EnvironmentObject var store: Store
    let item: InboxItem
    @State private var isHovered = false

    var body: some View {
        Row(isHovered: $isHovered, isBusy: false) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .fontWeight(item.isRead ? .regular : .semibold)
                    .foregroundStyle(item.isRead ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.title)
                if let body = item.body {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(body)
                }
            }
            Spacer(minLength: 4)
            if isHovered {
                if item.url != nil {
                    IconButton(symbol: "arrow.up.right.square", help: "Ouvrir le lien") { store.open(item) }
                }
                if !item.isRead {
                    IconButton(symbol: "envelope.open", help: "Marquer lu") { store.markRead(item) }
                }
                IconButton(symbol: "xmark", help: "Effacer") { store.dismiss(item) }
            } else {
                Text("\(item.source) · \(dueLabel(localMinute(item.createdAt)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var symbol: String {
        switch item.level {
        case .info: return item.isRead ? "circle" : "circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.level {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: Building blocks

/// A row of the list: hover highlight, dimmed while an action runs on it.
struct Row<Content: View>: View {
    @Binding var isHovered: Bool
    let isBusy: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
            .opacity(isBusy ? 0.4 : 1)
            .disabled(isBusy)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct CheckButton: View {
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isHovered ? "checkmark.circle" : "circle")
                .foregroundStyle(isHovered ? .green : .secondary)
                .font(.body)
        }
        .buttonStyle(.borderless)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .disabled(!isEnabled)
    }
}

struct KeyLink: View {
    @EnvironmentObject var store: Store
    let key: String

    @State private var isHovered = false

    var body: some View {
        // A plain button keeps its label's colour; a borderless one in a menu bar window draws
        // it in the secondary label colour, which reads as plain grey text.
        Button {
            store.open(key)
        } label: {
            // A pill, so the key reads as something to click at a glance: system blue, brighter
            // than the link colour, on a light tint that deepens under the pointer.
            Text(key)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(Color(nsColor: .systemBlue))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .systemBlue).opacity(isHovered ? 0.24 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Ouvrir dans Jira")
        .fixedSize()
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct PriorityBadge: View {
    let priority: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 14)
            .help(priority)
    }

    private var symbol: String {
        switch priorityRank(priority) {
        case 0: return "chevron.up.2"
        case 1: return "chevron.up"
        case 3: return "chevron.down"
        case 4: return "chevron.down.2"
        default: return "equal"
        }
    }

    private var color: Color {
        switch priorityRank(priority) {
        case 0: return .red
        case 1: return .orange
        case 3, 4: return .blue
        default: return .yellow
        }
    }
}

/// "auj. HH:MM" or "dem. HH:MM" for today and tomorrow, "DD/MM HH:MM" beyond.
func dueLabel(_ due: String) -> String {
    guard due.count >= 16 else { return due }
    let day = String(due.prefix(10)), time = String(due.suffix(5))
    let today = String(localMinute(Date()).prefix(10))
    if day == today { return "auj. \(time)" }
    if day == addDays(today, 1) { return "dem. \(time)" }
    return "\(day.dropFirst(8))/\(day.dropFirst(5).prefix(2)) \(time)"
}

/// How long ago a ticket was created: "3 j", "5 sem.".
func age(_ date: Date) -> String {
    let days = max(0, Int(Date().timeIntervalSince(date) / 86_400))
    return days < 21 ? "\(days) j" : "\(days / 7) sem."
}
