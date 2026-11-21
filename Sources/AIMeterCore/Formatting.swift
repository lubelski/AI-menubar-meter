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

public enum CompactDollars {
    /// A dollar amount in at most five characters, for the menu bar: "$0.42", "$4.20",
    /// "$42", "$123", "$1.2K", "$12K", "$1.2M".
    ///
    /// Cents show only under $10, where they are most of the amount.
    public static func string(_ dollars: Double) -> String {
        let value = max(dollars, 0)
        // Each step is tested against the rounded value, so $9.999 reads "$10" and not "$10.00".
        if value < 9.995 { return "$" + fixed(value, 2) }
        if value < 999.5 { return "$" + fixed(value, 0) }
        for (unit, suffix) in [(1e3, "K"), (1e6, "M")] {
            let scaled = value / unit
            if scaled < 9.95 { return "$" + fixed(scaled, 1) + suffix }
            if scaled < 999.5 { return "$" + fixed(scaled, 0) + suffix }
        }
        return "$" + fixed(value / 1e9, value < 9.95e9 ? 1 : 0) + "B"
    }

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
