import Foundation
import Testing
@testable import AIMeterCore

@Suite("Claude usage parsing")
struct ClaudeParsingTests {
    private let json = Data("""
    {
      "five_hour": { "utilization": 42.0, "resets_at": "2026-11-03T10:40:00.126236+00:00",
                     "limit_dollars": null, "used_dollars": null },
      "seven_day": { "utilization": 8.0, "resets_at": "2026-11-08T17:00:00.126260+00:00" },
      "seven_day_opus": null,
      "iguana_necktie": { "utilization": 46.17, "resets_at": "2026-11-05T07:59:00+00:00",
                          "limit_dollars": 250, "used_dollars": 115.44, "remaining_dollars": 134.56 },
      "extra_usage": { "is_enabled": false, "monthly_limit": null },
      "limits": [
        { "kind": "session", "percent": 42, "scope": null },
        { "kind": "weekly_scoped", "percent": 11, "scope": { "model": { "display_name": "Opus" } } }
      ]
    }
    """.utf8)

    @Test func parsesWindows() throws {
        let usage = try #require(ClaudeProvider.parse(json))
        #expect(usage.session?.fraction == 0.42)
        #expect(usage.weekly?.fraction == 0.08)
        #expect(usage.session?.duration == 18_000.0)
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_793_702_400))
    }

    @Test func findsDollarCreditRegardlessOfKeyName() throws {
        let credit = try #require(ClaudeProvider.parse(json)?.credit)
        #expect(credit.used == 115.44)
        #expect(credit.limit == 250)
        #expect(abs(credit.fraction - 0.46176) < 0.0001)
        #expect(credit.resetsAt == Date(timeIntervalSince1970: 1793865540))
    }

    @Test func parsesScopedWeeklyLimits() throws {
        let scoped = try #require(ClaudeProvider.parse(json)).scopedWeekly
        #expect(scoped == [ScopedLimit(name: "Opus", fraction: 0.11)])
    }

    @Test func toleratesMissingFields() throws {
        let usage = try #require(ClaudeProvider.parse(Data("{}".utf8)))
        #expect(usage.session == nil)
        #expect(usage.credit == nil)
    }
}

@Suite("Codex usage parsing")
struct CodexParsingTests {
    @Test func parsesPrimaryAndSecondaryWindows() throws {
        let json = Data("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 32, "limit_window_seconds": 18000, "reset_at": 1793701782 },
            "secondary_window": { "used_percent": 28, "limit_window_seconds": 604800, "reset_at": 1794084956 }
          }
        }
        """.utf8)
        let usage = try #require(CodexProvider.parse(json))
        #expect(usage.plan == "Plus")
        #expect(usage.session?.fraction == 0.32)
        #expect(usage.weekly?.duration == 604_800)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_084_956))
    }
}

@Suite("Derived values")
struct DerivedValueTests {
    @Test(arguments: [(0.0, UsageLevel.normal), (0.74, .normal), (0.75, .warning), (0.9, .critical), (1.0, .critical)])
    func levels(fraction: Double, expected: UsageLevel) {
        #expect(UsageLevel(fraction: fraction) == expected)
    }

    @Test func elapsedFraction() {
        let now = Date(timeIntervalSince1970: 0)
        let window = UsageWindow(fraction: 0.5, resetsAt: now.addingTimeInterval(3600), duration: 4 * 3600)
        #expect(window.elapsedFraction(now: now) == 0.75)
    }

    @Test func clampsFraction() {
        #expect(UsageWindow(fraction: 1.4, resetsAt: nil, duration: nil).fraction == 1)
    }

    @Test func shortResetText() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ResetText.string(for: now.addingTimeInterval(4 * 3600 + 12 * 60), now: now) == "Resets in 4h 12m")
        #expect(ResetText.string(for: now.addingTimeInterval(30), now: now) == "Resets in 1m")
        #expect(ResetText.string(for: now.addingTimeInterval(-5), now: now) == "Resetting…")
    }
}

@Suite("Meter style")
struct MeterStyleTests {
    @Test func usedShowsUsage() {
        #expect(MeterStyle.used.displayed(0.55) == 0.55)
    }

    @Test func remainingShowsWhatIsLeft() {
        #expect(abs(MeterStyle.remaining.displayed(0.55) - 0.45) < 1e-9)
        #expect(MeterStyle.remaining.displayed(0) == 1)
    }
}

@Suite("Anthropic Admin cost report")
struct CostReportTests {
    @Test func sumsAllItemsInCents() throws {
        let json = Data("""
        {
          "data": [
            { "starting_at": "2026-11-01T00:00:00Z", "ending_at": "2026-11-02T00:00:00Z",
              "results": [ { "amount": "1234.5", "currency": "USD" }, { "amount": "100", "currency": "USD" } ] },
            { "starting_at": "2026-11-02T00:00:00Z", "ending_at": "2026-11-03T00:00:00Z", "results": [] }
          ],
          "has_more": true,
          "next_page": "page_abc"
        }
        """.utf8)
        let report = try #require(AnthropicCostProvider.parse(json))
        #expect(report.cents == 1334.5)
        #expect(report.nextPage == "page_abc")
    }

    @Test func stopsWhenNoMorePages() throws {
        let json = Data(#"{ "data": [], "has_more": false, "next_page": null }"#.utf8)
        #expect(try #require(AnthropicCostProvider.parse(json)).nextPage == nil)
    }

    @Test func monthBoundsAreUTC() {
        let date = Date(timeIntervalSince1970: 1_793_865_540) // 2026-11-05 07:59 UTC
        let (start, next) = AnthropicCostProvider.utcMonth(containing: date)
        #expect(start.formatted(.iso8601) == "2026-11-01T00:00:00Z")
        #expect(next.formatted(.iso8601) == "2026-12-01T00:00:00Z")
    }
}

@Suite struct ClaudeCodeLoginTests {
    private func payload(token: String, expires: String, refreshExpires: String? = nil) -> Data {
        let refresh = refreshExpires.map { #", "refreshTokenExpiresAt": \#($0)"# } ?? ""
        return Data(#"{"claudeAiOauth": {"accessToken": "\#(token)", "expiresAt": \#(expires)\#(refresh), "subscriptionType": "max"}}"#.utf8)
    }

    @Test func decodesMillisecondTimestamps() throws {
        let login = try #require(ClaudeCodeLogin.decode(payload(token: "a", expires: "1794280796145", refreshExpires: "\"1796080834416\"")))
        #expect(login.accessToken == "a")
        #expect(login.plan == "max")
        #expect(login.expiresAt == Date(timeIntervalSince1970: 1_794_280_796.145))
        #expect(login.refreshExpiresAt == Date(timeIntervalSince1970: 1_796_080_834.416))
    }

    @Test func staleFileLosesToCurrentKeychainItem() throws {
        let stale = ClaudeCodeLogin.decode(payload(token: "old", expires: "1757000000000"))
        let current = ClaudeCodeLogin.decode(payload(token: "new", expires: "1794280796145"))
        #expect(ClaudeCodeLogin.newest([stale, current])?.accessToken == "new")
        #expect(ClaudeCodeLogin.newest([current, stale])?.accessToken == "new")
        #expect(ClaudeCodeLogin.newest([nil, stale])?.accessToken == "old")
    }

    @Test func tokenNearExpiryIsNotUsable() {
        let now = Date.now
        let login = ClaudeCodeLogin(accessToken: "a", expiresAt: now.addingTimeInterval(30),
                                    refreshExpiresAt: now.addingTimeInterval(-1), plan: nil)
        #expect(!login.isUsable(at: now))
        #expect(login.needsNewSignIn(at: now))
    }
}

@Suite struct ClaudeCodeResolveTests {
    private let now = Date.now
    private func login(_ token: String = "a", expiresIn: TimeInterval = 3600, refreshExpiresIn: TimeInterval = 86400) -> ClaudeCodeLogin {
        ClaudeCodeLogin(accessToken: token, expiresAt: now.addingTimeInterval(expiresIn),
                        refreshExpiresAt: now.addingTimeInterval(refreshExpiresIn), plan: "max")
    }

    @Test func usableLoginNeedsNoCLI() {
        #expect(ClaudeCodeLogin.resolve(login(), rejecting: nil) == .success(login()))
    }

    @Test func expiredOrRejectedTokenAsksTheCLI() {
        #expect(ClaudeCodeLogin.resolve(login(expiresIn: -10), rejecting: nil) == nil)
        #expect(ClaudeCodeLogin.resolve(login("a"), rejecting: "a") == nil)
        #expect(ClaudeCodeLogin.resolve(nil, rejecting: nil) == nil)
    }

    @Test func expiredRefreshTokenNeedsSignInWithoutAskingTheCLI() {
        #expect(ClaudeCodeLogin.resolve(login(expiresIn: -10, refreshExpiresIn: -1), rejecting: nil) == .failure(.loginExpired))
    }

    @Test func refreshedTokenWins() {
        let fresh = login("b")
        #expect(ClaudeCodeLogin.resolve(fresh, rejecting: "a", after: .ran(loggedIn: true)) == .success(fresh))
    }

    @Test func failuresAfterAskingTheCLI() {
        let stale = login(expiresIn: -10)
        #expect(ClaudeCodeLogin.resolve(stale, rejecting: nil, after: .ran(loggedIn: true)) == .failure(.refreshFailed))
        #expect(ClaudeCodeLogin.resolve(stale, rejecting: nil, after: .ran(loggedIn: nil)) == .failure(.refreshFailed))
        #expect(ClaudeCodeLogin.resolve(stale, rejecting: nil, after: .throttled) == .failure(.refreshFailed))
        #expect(ClaudeCodeLogin.resolve(stale, rejecting: nil, after: .ran(loggedIn: false)) == .failure(.signedOut))
        #expect(ClaudeCodeLogin.resolve(stale, rejecting: nil, after: .noCLI) == .failure(.cliNotFound))
        #expect(ClaudeCodeLogin.resolve(nil, rejecting: nil, after: .ran(loggedIn: nil)) == .failure(.signedOut))
        #expect(ClaudeCodeLogin.resolve(nil, rejecting: nil, after: .noCLI) == .failure(.cliNotFound))
    }
}

@Suite struct SubprocessTests {
    @Test func returnsOutput() async throws {
        let data = try await Subprocess.run("/bin/echo", ["hi"])
        #expect(String(decoding: data, as: UTF8.self) == "hi\n")
    }

    @Test func throwsOnNonzeroExit() async {
        await #expect(throws: Subprocess.Failure.self) { try await Subprocess.run("/usr/bin/false", []) }
    }

    @Test func detachedTimeoutLeavesTheProcessRunning() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "aimeter-\(UUID().uuidString)")
        let start = ContinuousClock.now
        await #expect(throws: Subprocess.Failure.self) {
            try await Subprocess.run("/bin/sh", ["-c", "sleep 1; touch '\(marker.path)'"], timeout: 0.2, onTimeout: .detach)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        try await Task.sleep(for: .seconds(1.5))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: marker)
    }

    @Test func terminatingTimeoutStopsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "aimeter-\(UUID().uuidString)")
        await #expect(throws: Subprocess.Failure.self) {
            try await Subprocess.run("/bin/sh", ["-c", "sleep 1; touch '\(marker.path)'"], timeout: 0.2)
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
