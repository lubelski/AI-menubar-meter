import Foundation

/// OpenRouter, read with a Management API key. An account shows either the prepaid
/// credit balance (`GET /api/v1/credits`) or one API key's spend against its limit,
/// found by hash in `GET /api/v1/keys`. Both routes reject regular API keys, but one
/// management key covers every key in the workspace, so the user never has to find
/// the keys that their programs use.
public struct OpenRouterProvider: Sendable {
    public init() {}

    public func fetch(
        _ account: Account, secrets: any SecretStore, now: Date = .now
    ) async throws(ProviderError) -> Reading {
        guard let managementKey = secrets.read(account.secretKey) else { throw .notSignedIn }

        guard let hash = account.openRouterKeyHash else {
            let data = try await Self.get("credits", managementKey)
            guard let dollars = Self.parseCredits(data) else { throw .unexpectedResponse }
            return Reading(tanks: [
                Tank(kind: .pool, title: "Balance", used: dollars.fraction, dollars: dollars),
            ])
        }

        let keys = try await Self.listKeys(managementKey: managementKey)
        guard let key = keys.first(where: { $0.hash == hash }) else { throw .keyNotFound }
        // A key without a limit has nothing to drain, so it shows what it spent.
        guard let tank = key.tank(now: now) else { return Reading(spend: key.spend(now: now)) }
        return Reading(tanks: [tank])
    }

    /// Every enabled, unexpired API key in the management key's workspace.
    public static func listKeys(managementKey: String) async throws(ProviderError) -> [OpenRouterKey] {
        var keys: [OpenRouterKey] = []
        while true {
            let data = try await get("keys?offset=\(keys.count)", managementKey)
            guard let page = parseKeys(data) else { throw .unexpectedResponse }
            keys += page
            // The route returns at most 100 keys per page.
            if page.count < 100 { return keys }
        }
    }

    private static func get(_ path: String, _ managementKey: String) async throws(ProviderError) -> Data {
        do {
            return try await HTTP.get(URL(string: "https://openrouter.ai/api/v1/\(path)")!, headers: [
                "Authorization": "Bearer \(managementKey)",
            ])
        } catch .sessionExpired {
            throw .keyRejected
        }
    }

    /// Credits used against credits bought, in dollars.
    static func parseCredits(_ data: Data) -> Dollars? {
        struct Response: Decodable {
            struct Credits: Decodable {
                var total_credits: Double
                var total_usage: Double
            }
            var data: Credits
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Dollars(used: response.data.total_usage, limit: response.data.total_credits)
    }

    static func parseKeys(_ data: Data) -> [OpenRouterKey]? {
        struct Response: Decodable { var data: [OpenRouterKey] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.data
    }
}

/// One OpenRouter API key, as `GET /api/v1/keys` describes it. Amounts are dollars.
public struct OpenRouterKey: Decodable, Sendable, Equatable, Identifiable {
    public var hash: String
    public var name: String
    /// The limit, or `nil` for a key without one.
    public var limit: Double?
    public var limitRemaining: Double?
    /// `daily`, `weekly` or `monthly`; `nil` when the limit never resets.
    public var limitReset: String?
    /// Spend in the current UTC day and month.
    public var usageDaily: Double
    public var usageMonthly: Double

    public var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, name, limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageMonthly = "usage_monthly"
    }

    /// What the key spent today and this month, for a key without a limit. OpenRouter
    /// counts both in UTC, as Anthropic's cost report does.
    func spend(now: Date) -> Spend {
        Spend(today: usageDaily, monthToDate: usageMonthly,
              resetsAt: UTCWindow.daily.containing(now).end, isUTCDay: true)
    }

    /// The key's spend against its limit, or `nil` for a key without a limit.
    func tank(now: Date) -> Tank? {
        guard let limit else { return nil }
        let dollars = Dollars(used: limit - (limitRemaining ?? limit), limit: limit)
        let window = limitReset.flatMap(UTCWindow.init(rawValue:))?.containing(now)
        let title = switch limitReset {
        case "daily": "Today"
        case "weekly": "This week"
        case "monthly": "This month"
        default: "Key limit"
        }
        return Tank(kind: .pool, title: title, used: dollars.fraction,
                    resetsAt: window?.end, duration: window?.duration, dollars: dollars)
    }
}

/// The calendar windows OpenRouter resets limits on, in UTC. Weeks start on Monday.
enum UTCWindow: String {
    case daily, weekly, monthly

    func containing(_ date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2
        let component: Calendar.Component = switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
        return calendar.dateInterval(of: component, for: date)!
    }
}
