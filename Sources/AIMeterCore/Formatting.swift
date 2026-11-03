import Foundation

enum Timestamp {
    /// Parses ISO-8601 timestamps such as `2026-11-03T10:40:00.126236+00:00`.
    /// Fractional seconds are dropped: they vary in precision and don't matter here.
    static func parse(_ string: String) -> Date? {
        let trimmed = string.replacing(/\.\d+/, with: "")
        return try? Date(trimmed, strategy: .iso8601)
    }
}

public enum ResetText {
    /// "Resets in 4h 12m" within a day, otherwise "Resets Sat 9:00 AM".
    public static func string(for date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Resetting…" }
        guard seconds < 24 * 3600 else {
            return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(max(minutes, 1))m"
    }
}
