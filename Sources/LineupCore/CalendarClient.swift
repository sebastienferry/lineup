import EventKit
import Foundation

/// The agenda, from the calendars macOS already syncs (a Google account added in Calendar
/// included), so no OAuth flow of its own.
public struct CalendarError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public final class CalendarClient: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    /// Asks for calendar access the first time; answers whether it is granted.
    public func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The events from the start of today for `days` days, without the ones the user declined
    /// and the cancelled ones.
    public func events(days: Int, now: Date = Date()) -> [AgendaEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
                return event.status != .canceled && !declined
            }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                AgendaEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    meetURL: Self.meetURL(of: event)
                )
            }
    }

    /// A calendar events can be added to.
    public struct WritableCalendar: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let account: String
    }

    public func writableCalendars() -> [WritableCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { WritableCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Adds an event, answering its identifier.
    public func addEvent(title: String, start: Date, minutes: Int, calendarId: String, url: URL?, notes: String?) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarId) else {
            throw CalendarError(message: "calendrier introuvable, choisis-en un autre")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        event.url = url
        event.notes = notes
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    public func removeEvent(id: String) throws {
        guard let event = store.event(withIdentifier: id) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    /// The video call link: the event's URL, else the first Meet, Zoom or Teams link in its notes
    /// or location.
    static func meetURL(of event: EKEvent) -> URL? {
        if let url = event.url { return url }
        let text = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com)/[^\s<>"]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
