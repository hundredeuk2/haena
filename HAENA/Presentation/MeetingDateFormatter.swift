import Foundation

/// Locale/TimeZone-aware date display for project and meeting timestamps. Both are taken as
/// parameters (defaulting to the system's current values) so tests can pin them for
/// deterministic assertions instead of depending on the machine running the test. Never used
/// to change what's stored — the domain model keeps `Date`, only this presentation layer
/// converts to a displayable string.
struct MeetingDateFormatter: Sendable {
    let locale: Locale
    let timeZone: TimeZone

    init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
