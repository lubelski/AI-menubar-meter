import Foundation

/// Whether meters show what's been used (filling up) or what's left (draining).
public enum MeterStyle: String, CaseIterable, Identifiable, Sendable {
    case used
    case remaining

    public var id: Self { self }

    /// Converts a used fraction into the fraction the meter should display.
    public func displayed(_ used: Double) -> Double {
        switch self {
        case .used: used
        case .remaining: 1 - used
        }
    }
}

/// The services AI Meter tracks; each can be hidden.
public enum Service: String, CaseIterable, Identifiable, Sendable {
    case claude
    case openAI
    case apiCredit

    public var id: Self { self }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .apiCredit: "API Credit"
        }
    }

    /// `UserDefaults` key controlling visibility.
    public var visibilityKey: String { "show.\(rawValue)" }
}

/// `UserDefaults` keys and defaults, shared by the app's `@AppStorage` properties.
public enum Preferences {
    public static let meterStyle = "meterStyle"
    public static let showPace = "showPace"
    public static let refreshMinutes = "refreshMinutes"

    public static let refreshChoices = [1, 2, 5, 15]
    public static let defaultRefreshMinutes = 5

    public static var refreshInterval: Duration {
        let minutes = UserDefaults.standard.object(forKey: refreshMinutes) as? Int ?? defaultRefreshMinutes
        return .seconds(60 * max(minutes, 1))
    }
}
