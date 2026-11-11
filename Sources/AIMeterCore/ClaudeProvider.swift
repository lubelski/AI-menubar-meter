import Foundation

/// Fetches Claude plan utilization from the same endpoint Claude Code's `/usage` uses.
public struct ClaudeProvider: Sendable {
    public init() {}

    public func fetch(_ account: Account, secrets: any SecretStore) async throws(ProviderError) -> Reading {
        var (token, plan) = try await Credentials.claudeAccessToken(account, secrets: secrets)
        let data: Data
        do {
            data = try await Self.get(token)
        } catch .sessionExpired where account.credential == .cli {
            // Claude Code may have rotated its token, or the server revoked it early.
            // Let the CLI refresh it, then try once more.
            let login = try await Credentials.claudeCodeLogin(rejecting: token)
            (token, plan) = (login.accessToken, login.plan)
            do {
                data = try await Self.get(token)
            } catch .sessionExpired {
                throw .claudeCode(.refreshFailed)
            }
        } catch .sessionExpired where account.credential == .oauth {
            // The server can revoke a token before it expires. Refresh once and try again.
            token = try await OAuthSessions.shared.usableLogin(
                for: account, secrets: secrets, rejecting: token).accessToken
            data = try await Self.get(token)
        }
        guard var reading = Self.parse(data) else { throw .unexpectedResponse }
        reading.plan = plan?.capitalized
        return reading
    }

    private static func get(_ token: String) async throws(ProviderError) -> Data {
        try await HTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ]
        )
    }

    static func parse(_ data: Data) -> Reading? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        let scoped = (response.limits ?? [])
            .filter { $0.kind == "weekly_scoped" }
            .compactMap { limit -> ScopedLimit? in
                guard let name = limit.scope?.model?.display_name else { return nil }
                return ScopedLimit(name: name, fraction: limit.percent / 100)
            }

        // The plan's API credit arrives under an internal codename that changes, so it's
        // identified by shape instead: the only windows that carry a dollar limit.
        let credit = response.dollarWindows
            .sorted { $0.key < $1.key }
            .lazy
            .compactMap { _, window -> Tank? in
                guard let limit = window.limit_dollars, limit > 0 else { return nil }
                let dollars = Dollars(used: window.used_dollars ?? 0, limit: limit)
                return Tank(kind: .pool, title: "API credit", used: dollars.fraction,
                            resetsAt: window.resetDate, dollars: dollars)
            }
            .first

        let tanks = [
            response.five_hour?.tank(.session, title: "Session", duration: 5 * 3600),
            response.seven_day?.tank(.weekly, title: "Weekly", duration: 7 * 86400),
            credit,
        ]
        return Reading(tanks: tanks.compactMap(\.self), scoped: scoped)
    }

    // MARK: Wire format

    private struct Window: Decodable {
        var utilization: Double?
        var resets_at: String?
        var limit_dollars: Double?
        var used_dollars: Double?

        var resetDate: Date? { resets_at.flatMap(Timestamp.parse) }

        func tank(_ kind: Tank.Kind, title: String, duration: TimeInterval) -> Tank? {
            guard let utilization else { return nil }
            return Tank(kind: kind, title: title, used: utilization / 100, resetsAt: resetDate, duration: duration)
        }
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var display_name: String? }
            var model: Model?
        }
        var kind: String
        var percent: Double
        var scope: Scope?
    }

    private struct Response: Decodable {
        var five_hour: Window?
        var seven_day: Window?
        var limits: [Limit]?
        var dollarWindows: [String: Window]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            five_hour = try? container.decodeIfPresent(Window.self, forKey: Key(stringValue: "five_hour"))
            seven_day = try? container.decodeIfPresent(Window.self, forKey: Key(stringValue: "seven_day"))
            limits = try? container.decodeIfPresent([Limit].self, forKey: Key(stringValue: "limits"))

            var windows: [String: Window] = [:]
            for key in container.allKeys {
                if let window = try? container.decodeIfPresent(Window.self, forKey: key),
                   window.limit_dollars != nil {
                    windows[key.stringValue] = window
                }
            }
            dollarWindows = windows
        }
    }
}
