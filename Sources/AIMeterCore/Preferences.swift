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
///
/// Case order is display order in the menu bar, the panel, and Settings.
/// Services that share a brand are adjacent so one logo can label them together.
public enum Service: String, CaseIterable, Identifiable, Sendable {
    case claude
    case apiCredit
    case openAI

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

/// The company behind a service. Its logo labels that service's meters.
public enum Brand: Sendable, Equatable {
    case anthropic
    case openAI

    public var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }
}

extension Service {
    /// API credit is Claude's (plan credit or the Anthropic Admin API), so it shares Claude's logo.
    public var brand: Brand {
        switch self {
        case .claude, .apiCredit: .anthropic
        case .openAI: .openAI
        }
    }
}

/// `UserDefaults` keys and defaults, shared by the app's `@AppStorage` properties.
public enum Preferences {
    public static let meterStyle = "meterStyle"
    /// Meters drain by default: a full bar means plenty left.
    public static let defaultMeterStyle = MeterStyle.remaining
    public static let showPace = "showPace"
    public static let showLogos = "showLogos"
    public static let refreshMinutes = "refreshMinutes"

    public static let refreshChoices = [1, 2, 5, 15]
    public static let defaultRefreshMinutes = 5

    public static var refreshInterval: Duration {
        let minutes = UserDefaults.standard.object(forKey: refreshMinutes) as? Int ?? defaultRefreshMinutes
        return .seconds(60 * max(minutes, 1))
    }
}
