import Foundation

/// Fetches ChatGPT-plan Codex limits from the endpoint the Codex CLI uses for `/status`.
public struct CodexProvider: Sendable {
    public init() {}

    public func fetch(_ config: AuthConfig) async throws(ProviderError) -> CodexUsage {
        let (token, accountID) = try Credentials.openAITokens(config)
        var headers = ["Authorization": "Bearer \(token)"]
        headers["ChatGPT-Account-Id"] = accountID
        let data = try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        guard let usage = Self.parse(data) else { throw .unexpectedResponse }
        return usage
    }

    static func parse(_ data: Data) -> CodexUsage? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return CodexUsage(
            plan: response.plan_type?.capitalized,
            session: response.rate_limit?.primary_window?.usageWindow,
            weekly: response.rate_limit?.secondary_window?.usageWindow
        )
    }

    // MARK: Wire format

    private struct Window: Decodable {
        var used_percent: Double
        var limit_window_seconds: Double?
        var reset_at: Double?

        var usageWindow: UsageWindow {
            UsageWindow(
                fraction: used_percent / 100,
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
