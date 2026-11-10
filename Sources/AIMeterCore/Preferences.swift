import Foundation

/// `UserDefaults` keys and defaults, shared by the app's `@AppStorage` properties.
public enum Preferences {
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
