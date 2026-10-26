import Foundation

/// A quick add: a title, and when to work on it.
public struct QuickTask: Equatable, Sendable {
    public let title: String
    /// Local time, "YYYY-MM-DD HH:MM".
    public let at: String
    /// Whether the text named a time with "@"; a ticket only gets a calendar block when it did.
    public let isScheduled: Bool

    public init(title: String, at: String, isScheduled: Bool) {
        self.title = title
        self.at = at
        self.isScheduled = isScheduled
    }
}

/// Parses "Title @ 14:30", "Title @ demain 10h", "Title @ tomorrow 9:00" or
/// "Title @ 2026-10-14 09:00". Without "@", the time is the next full hour, or tomorrow 09:30
/// after 18:00. `now` is the local "YYYY-MM-DD HH:MM".
public func parseQuickTask(_ input: String, now: String) -> QuickTask? {
    let at = input.range(of: "@", options: .backwards)
    let title = (at.map { String(input[..<$0.lowerBound]) } ?? input).trimmingCharacters(in: .whitespaces)
    let when = (at.map { String(input[$0.upperBound...]) } ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    guard !title.isEmpty, now.count >= 16 else { return nil }

    let today = String(now.prefix(10))
    let hourNow = Int(now.dropFirst(11).prefix(2)) ?? 9

    func time(_ text: String, fallback: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*[:h]\\s*(\\d{2})?"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text)
        else { return fallback }
        let hour = Int(text[hourRange]) ?? 9
        let minutes = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "00"
        return String(format: "%02d:%@", hour, minutes)
    }

    if when.isEmpty {
        let at = hourNow >= 18 ? "\(addDays(today, 1)) 09:30" : "\(today) \(String(format: "%02d", hourNow + 1)):00"
        return QuickTask(title: title, at: at, isScheduled: false)
    }
    if let dateRange = when.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
        let date = String(when[dateRange])
        let rest = when.replacingCharacters(in: dateRange, with: "")
        return QuickTask(title: title, at: "\(date) \(time(rest, fallback: "09:30"))", isScheduled: true)
    }
    if when.hasPrefix("demain") || when.hasPrefix("tomorrow") {
        return QuickTask(title: title, at: "\(addDays(today, 1)) \(time(when, fallback: "09:30"))", isScheduled: true)
    }
    let fallback = String(format: "%02d:00", min(hourNow + 1, 23))
    return QuickTask(title: title, at: "\(today) \(time(when, fallback: fallback))", isScheduled: true)
}

/// "YYYY-MM-DD" plus `days`, on the calendar date alone.
public func addDays(_ day: String, _ days: Int) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: day) else { return day }
    return formatter.string(from: date.addingTimeInterval(TimeInterval(days * 86_400)))
}

/// The local "YYYY-MM-DD HH:MM" of a date.
public func localMinute(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
