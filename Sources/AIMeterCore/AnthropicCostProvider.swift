import Foundation

/// Claude API spend from the Anthropic Admin API: today's, and the month's so far.
///
/// The cost report comes in whole UTC days and has no finer bucket, so "today" is the
/// current UTC day. One request for the month covers both numbers.
public struct AnthropicCostProvider: Sendable {
    public init() {}

    public func fetch(
        _ account: Account, secrets: any SecretStore, now: Date = .now
    ) async throws(ProviderError) -> Reading {
        guard let key = secrets.read(account.secretKey) else { throw .notSignedIn }

        let monthStart = Self.utcMonth(containing: now).start
        var days: [Day] = []
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
            days += report.days
            page = report.nextPage
        } while page != nil

        return Reading(spend: Self.spend(from: days, now: now))
    }

    /// One UTC day of the report.
    struct Day: Equatable {
        var start: Date
        var cents: Double
    }

    static func spend(from days: [Day], now: Date) -> Spend {
        let today = utcDay(containing: now)
        // A day with no cost yet may be missing from the report or present and empty.
        let todayCents = days.filter { $0.start == today.start }.map(\.cents).reduce(0, +)
        let monthCents = days.map(\.cents).reduce(0, +)
        return Spend(today: todayCents / 100, monthToDate: monthCents / 100, resetsAt: today.next, isUTCDay: true)
    }

    /// Each day's cost items summed, in cents, plus the cursor for the next page.
    static func parse(_ data: Data) -> (days: [Day], nextPage: String?)? {
        struct Report: Decodable {
            struct Bucket: Decodable {
                struct Item: Decodable { var amount: String }
                var starting_at: String
                var results: [Item]
            }
            var data: [Bucket]
            var has_more: Bool?
            var next_page: String?
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        var days: [Day] = []
        for bucket in report.data {
            guard let start = Timestamp.parse(bucket.starting_at) else { return nil }
            days.append(Day(start: start, cents: bucket.results.compactMap { Double($0.amount) }.reduce(0, +)))
        }
        return (days, report.has_more == true ? report.next_page : nil)
    }

    static func utcDay(containing date: Date) -> (start: Date, next: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let day = calendar.dateInterval(of: .day, for: date)!
        return (day.start, day.end)
    }

    static func utcMonth(containing date: Date) -> (start: Date, next: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = calendar.dateInterval(of: .month, for: date)!
        return (start.start, start.end)
    }
}
