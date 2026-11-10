import Foundation

/// Month-to-date Claude API spend from the Anthropic Admin API, measured against a
/// user-set monthly budget (the API itself has no notion of a limit).
public struct AnthropicCostProvider: Sendable {
    public init() {}

    public func fetch(
        _ account: Account, secrets: any SecretStore, now: Date = .now
    ) async throws(ProviderError) -> Reading {
        guard let key = secrets.read(account.secretKey) else { throw .notSignedIn }

        let (monthStart, nextMonth) = Self.utcMonth(containing: now)
        var spentCents = 0.0
        var page: String?
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: monthStart.formatted(.iso8601)),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }

            let data: Data
            do {
                data = try await HTTP.get(components.url!, headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                ])
            } catch .sessionExpired {
                throw .keyRejected
            }
            guard let report = Self.parse(data) else { throw .unexpectedResponse }
            spentCents += report.cents
            page = report.nextPage
        } while page != nil

        let dollars = Dollars(used: spentCents / 100, limit: account.monthlyBudget ?? Account.defaultMonthlyBudget)
        return Reading(tanks: [
            Tank(kind: .pool, title: "This month", used: dollars.fraction, resetsAt: nextMonth, dollars: dollars),
        ])
    }

    /// Sum of every cost item, in cents, plus the cursor for the next page.
    static func parse(_ data: Data) -> (cents: Double, nextPage: String?)? {
        struct Report: Decodable {
            struct Bucket: Decodable {
                struct Item: Decodable { var amount: String }
                var results: [Item]
            }
            var data: [Bucket]
            var has_more: Bool?
            var next_page: String?
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        let cents = report.data.flatMap(\.results).compactMap { Double($0.amount) }.reduce(0, +)
        return (cents, report.has_more == true ? report.next_page : nil)
    }

    static func utcMonth(containing date: Date) -> (start: Date, next: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = calendar.dateInterval(of: .month, for: date)!
        return (start.start, start.end)
    }
}
