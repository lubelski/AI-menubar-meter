import Foundation

/// Fetches ChatGPT-plan Codex limits from the endpoint the Codex CLI uses for `/status`.
public struct CodexProvider: Sendable {
    public init() {}

    public func fetch(_ account: Account, secrets: any SecretStore) async throws(ProviderError) -> Reading {
        let (token, accountID) = try Credentials.codexTokens(account, secrets: secrets)
        var headers = ["Authorization": "Bearer \(token)"]
        headers["ChatGPT-Account-Id"] = accountID
        let data = try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        guard let reading = Self.parse(data) else { throw .unexpectedResponse }
        return reading
    }

    static func parse(_ data: Data) -> Reading? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let tanks = [
            response.rate_limit?.primary_window?.tank(.session, title: "Session"),
            response.rate_limit?.secondary_window?.tank(.weekly, title: "Weekly"),
        ]
        return Reading(plan: response.plan_type?.capitalized, tanks: tanks.compactMap(\.self))
    }

    // MARK: Wire format

    private struct Window: Decodable {
        var used_percent: Double
        var limit_window_seconds: Double?
        var reset_at: Double?

        func tank(_ kind: Tank.Kind, title: String) -> Tank {
            Tank(
                kind: kind, title: title, used: used_percent / 100,
                resetsAt: reset_at.map(Date.init(timeIntervalSince1970:)),
                duration: limit_window_seconds
            )
        }
    }

    private struct Response: Decodable {
        struct RateLimit: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        var plan_type: String?
        var rate_limit: RateLimit?
    }
}
