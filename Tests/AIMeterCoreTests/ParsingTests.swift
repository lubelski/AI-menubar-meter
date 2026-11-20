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
        { "kind": "weekly_scoped", "percent": 11, "scope": { "model": { "display_name": "Opus" } } },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 82, "severity": "warning",
          "resets_at": "2026-11-08T17:00:00.126457+00:00", "is_active": true,
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
      ]
    }
    """.utf8)

    @Test func parsesWindows() throws {
        let reading = try #require(ClaudeProvider.parse(json))
        #expect(reading.tank(.session)?.used == 0.42)
        #expect(reading.tank(.weekly)?.used == 0.08)
        #expect(reading.tank(.session)?.duration == 18_000.0)
        #expect(reading.tank(.session)?.resetsAt == Date(timeIntervalSince1970: 1_793_702_400))
    }

    @Test func findsDollarCreditRegardlessOfKeyName() throws {
        let credit = try #require(ClaudeProvider.parse(json)?.tank(.pool))
        #expect(credit.dollars == Dollars(used: 115.44, limit: 250))
        #expect(abs(credit.used - 0.46176) < 0.0001)
        #expect(credit.resetsAt == Date(timeIntervalSince1970: 1793865540))
    }

    @Test func parsesScopedWeeklyLimits() throws {
        let scoped = try #require(ClaudeProvider.parse(json)).scoped
        #expect(scoped == [ScopedLimit(name: "Opus", fraction: 0.11)])
    }

    @Test func fableLimitBecomesATank() throws {
        let reading = try #require(ClaudeProvider.parse(json))
        let fable = try #require(reading.tank(.fable))
        #expect(fable.title == "Fable")
        #expect(fable.used == 0.82)
        #expect(fable.duration == 604_800.0)
        #expect(fable.resetsAt == Date(timeIntervalSince1970: 1_794_157_200))
        #expect(reading.tanks.map(\.kind) == [.session, .fable, .weekly, .pool])
    }

    @Test func toleratesMissingFields() throws {
        let reading = try #require(ClaudeProvider.parse(Data("{}".utf8)))
        #expect(reading.tanks.isEmpty)
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
        let reading = try #require(CodexProvider.parse(json))
        #expect(reading.plan == "Plus")
        #expect(reading.tank(.session)?.used == 0.32)
        #expect(reading.tank(.weekly)?.duration == 604_800)
        #expect(reading.tank(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_794_084_956))
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
        let tank = Tank(kind: .session, title: "Session", used: 0.5,
                        resetsAt: now.addingTimeInterval(3600), duration: 4 * 3600)
        #expect(tank.elapsedFraction(now: now) == 0.75)
    }

    @Test func clampsFraction() {
        let tank = Tank(kind: .weekly, title: "Weekly", used: 1.4)
        #expect(tank.used == 1)
        #expect(tank.remaining == 0)
    }

    @Test func shortResetText() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ResetText.string(for: now.addingTimeInterval(4 * 3600 + 12 * 60), now: now) == "Resets in 4h 12m")
        #expect(ResetText.string(for: now.addingTimeInterval(30), now: now) == "Resets in 1m")
        #expect(ResetText.string(for: now.addingTimeInterval(-5), now: now) == "Resetting…")
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
        #expect(report.days.map(\.cents) == [1334.5, 0])
        #expect(report.days.map { $0.start.formatted(.iso8601) } == ["2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z"])
        #expect(report.nextPage == "page_abc")
    }

    @Test func todayIsTheCurrentUTCDayAndTheMonthIsEveryDay() {
        let day = { (iso: String) in try! Date(iso, strategy: .iso8601) }
        let days = [
            AnthropicCostProvider.Day(start: day("2026-11-03T00:00:00Z"), cents: 5000),
            AnthropicCostProvider.Day(start: day("2026-11-04T00:00:00Z"), cents: 2500),
            AnthropicCostProvider.Day(start: day("2026-11-05T00:00:00Z"), cents: 1234),
        ]
        let now = Date(timeIntervalSince1970: 1_793_865_540) // 2026-11-05 07:59 UTC
        let spend = AnthropicCostProvider.spend(from: days, now: now)
        #expect(spend.today == 12.34)
        #expect(spend.monthToDate == 87.34)
        #expect(spend.resetsAt.formatted(.iso8601) == "2026-11-06T00:00:00Z")
    }

    @Test func aDayMissingFromTheReportCountsAsNothingSpent() {
        let yesterday = AnthropicCostProvider.Day(start: try! Date("2026-11-04T00:00:00Z", strategy: .iso8601), cents: 2500)
        let now = Date(timeIntervalSince1970: 1_793_865_540)
        #expect(AnthropicCostProvider.spend(from: [yesterday], now: now).today == 0)
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

@Suite("OpenRouter")
struct OpenRouterTests {
    private let now = Date(timeIntervalSince1970: 1_795_176_000) // Thu 2026-11-20 08:00 UTC

    private func key(limit: String, reset: String, remaining: String, usage: Double = 6.85, today: Double = 0) throws -> OpenRouterKey {
        let json = Data("""
        { "data": [ { "hash": "abc", "name": "Rheo", "label": "sk-or-v1-0e6...2ea", "disabled": false,
                      "limit": \(limit), "limit_remaining": \(remaining), "limit_reset": \(reset),
                      "usage": 6.85, "usage_daily": \(today), "usage_weekly": 0, "usage_monthly": \(usage) } ] }
        """.utf8)
        return try #require(OpenRouterProvider.parseKeys(json)?.first)
    }

    @Test func creditsAreUsageAgainstCreditsBought() throws {
        let json = Data(#"{ "data": { "total_credits": 100.5, "total_usage": 25.75 } }"#.utf8)
        let dollars = try #require(OpenRouterProvider.parseCredits(json))
        #expect(dollars == Dollars(used: 25.75, limit: 100.5))
    }

    @Test func errorBodyIsNotAReading() {
        let json = Data(#"{ "error": { "code": 403, "message": "Only management keys can perform this operation" } }"#.utf8)
        #expect(OpenRouterProvider.parseCredits(json) == nil)
        #expect(OpenRouterProvider.parseKeys(json) == nil)
    }

    @Test func monthlyLimitResetsAtTheNextUTCMonth() throws {
        let tank = try #require(key(limit: "50", reset: #""monthly""#, remaining: "43.15").tank(now: now))
        #expect(tank.title == "This month")
        #expect(abs(tank.dollars!.used - 6.85) < 0.0001)
        #expect(tank.dollars!.limit == 50)
        #expect(tank.resetsAt?.formatted(.iso8601) == "2026-12-01T00:00:00Z")
        #expect(tank.duration == TimeInterval(30 * 86_400))
    }

    @Test func weeklyLimitResetsOnMonday() throws {
        let tank = try #require(key(limit: "20", reset: #""weekly""#, remaining: "15").tank(now: now))
        #expect(tank.title == "This week")
        #expect(tank.resetsAt?.formatted(.iso8601) == "2026-11-23T00:00:00Z")
        #expect(tank.duration == TimeInterval(7 * 86_400))
    }

    @Test func limitThatNeverResetsHasNoResetTime() throws {
        let tank = try #require(key(limit: "10", reset: "null", remaining: "4").tank(now: now))
        #expect(tank.title == "Key limit")
        #expect(tank.dollars == Dollars(used: 6, limit: 10))
        #expect(tank.resetsAt == nil)
    }

    @Test func keyWithoutALimitShowsWhatItSpent() throws {
        let key = try key(limit: "null", reset: "null", remaining: "null", usage: 6.97, today: 1.25)
        #expect(key.tank(now: now) == nil)
        let spend = key.spend(now: now)
        #expect(spend.today == 1.25)
        #expect(spend.monthToDate == 6.97)
        #expect(spend.isUTCDay)
        #expect(spend.resetsAt.formatted(.iso8601) == "2026-11-21T00:00:00Z")
    }

    @Test func anAccountWhoseReadingIsSpendShowsAChipAndNoEmptyTank() {
        var state = AccountState(account: Account(kind: .openRouter, openRouterKeyHash: "abc"))
        #expect(state.showsSpend == false)
        #expect(state.slots.map(\.kind) == [.pool])
        state.reading = Reading(spend: Spend(today: 1.25, monthToDate: 6.97, resetsAt: now, isUTCDay: true))
        #expect(state.showsSpend)
        #expect(state.slots.isEmpty)
    }

    @Test func noKeyMeansNotSignedIn() async {
        let account = Account(kind: .openRouter)
        #expect(account.credential == .pasted)
        #expect(account.openRouterKeyHash == nil)
        let result = await Providers.fetch(account, secrets: MemorySecrets([:]))
        #expect(result == .failure(.notSignedIn))
    }

    @Test func accountsSavedBeforeKeyChoiceStillDecode() throws {
        let json = Data(#"{ "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "kind": "openRouter", "name": "OpenRouter", "isVisible": true, "credential": "pasted" }"#.utf8)
        let account = try JSONDecoder().decode(Account.self, from: json)
        #expect(account.openRouterKeyHash == nil)
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

@Suite("Spend")
struct SpendTests {
    @Test(arguments: [
        (0, "$0.00"), (0.4, "$0.40"), (4.2, "$4.20"), (9.994, "$9.99"), (9.996, "$10"),
        (42.4, "$42"), (123, "$123"), (999.4, "$999"), (999.6, "$1.0K"), (1234, "$1.2K"),
        (9960, "$10K"), (12_345, "$12K"), (123_456, "$123K"), (999_600, "$1.0M"), (1_234_567, "$1.2M"),
    ])
    func compactDollarsStayWithinFiveCharacters(dollars: Double, text: String) {
        #expect(CompactDollars.string(dollars) == text)
        #expect(text.count <= 5)
    }

    @Test func theAmountChangesColorAtEachThreshold() {
        let account = Account(kind: .anthropicAPI, spendWarning: 50, spendCritical: 100)
        #expect(account.spendLevel(49.99) == .normal)
        #expect(account.spendLevel(50) == .warning)
        #expect(account.spendLevel(100) == .critical)
    }

    @Test func anAccountWithNoThresholdsNeverChangesColor() {
        #expect(Account(kind: .anthropicAPI).spendLevel(1_000_000) == .normal)
    }

    @Test func aNewThresholdKeepsTheReading() {
        let account = Account(kind: .anthropicAPI)
        var changed = account
        changed.spendWarning = 50
        #expect(account.readsTheSame(as: changed))
    }
}

@Suite("Claude Code local spend")
struct ClaudeCodeLocalTests {
    private func line(
        id: String, request: String = "req", time: String = "2026-11-05T07:00:00.123Z", model: String = "claude-opus-5-5",
        input: Int = 0, output: Int = 0, read: Int = 0, write5m: Int = 0, write1h: Int = 0
    ) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)},"speed":"standard"}}}"#
    }

    @Test func pricesEachKindOfToken() throws {
        // Opus 5.5: $4 in, $20 out, cache reads at 0.05x, 5-minute writes at 1.25x, 1-hour writes at 2x.
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let dollars = try #require(ModelPrices.dollars(for: usage, model: "claude-opus-5-5"))
        #expect(abs(dollars - (4 + 20 + 0.2 + 5 + 8)) < 1e-9)
    }

    @Test func theLongestModelPrefixWins() {
        #expect(ModelPrices.price(for: "claude-opus-5-5")?.input == 4)
        #expect(ModelPrices.price(for: "claude-opus-5")?.input == 5)
        #expect(ModelPrices.price(for: "claude-haiku-4-5-20251001")?.input == 1)
        #expect(ModelPrices.price(for: "claude-unknown-9") == nil)
    }

    @Test func fastModeAndLongHaikuPromptsCostMore() throws {
        var usage = TokenUsage(input: 1_000_000)
        usage.isFast = true
        #expect(ModelPrices.dollars(for: usage, model: "claude-fable-5-2") == 16)
        #expect(ModelPrices.dollars(for: TokenUsage(input: 100_000), model: "claude-haiku-5-5") == 0.01)
        #expect(ModelPrices.dollars(for: TokenUsage(input: 200_000), model: "claude-haiku-5-5") == 0.1)
    }

    @Test func aResponseLoggedOncePerBlockCountsOnce() {
        let log = [
            line(id: "msg_1", output: 1_000_000),
            line(id: "msg_1", output: 1_000_000),
            #"{"type":"user","timestamp":"2026-11-05T07:00:01Z","message":{"role":"user","content":"the word \"usage\" in a prompt"}}"#,
            line(id: "msg_2", output: 500_000),
            line(id: "msg_3", model: "<synthetic>"),
            "not json",
        ].joined(separator: "\n")
        let responses = ClaudeCodeLog.parse(Data(log.utf8))
        #expect(responses.map(\.id) == ["msg_1|req", "msg_2|req"])
        #expect(responses.map(\.dollars) == [20, 10])
    }

    @Test func todayAndTheMonthFollowTheLocalCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = try! Date("2026-11-05T20:00:00Z", strategy: .iso8601) // noon in Los Angeles
        func response(_ id: String, _ time: String, _ dollars: Double?, model: String = "claude-opus-5-5") -> ClaudeCodeLog.Response {
            .init(id: id, time: try! Date(time, strategy: .iso8601), model: model, dollars: dollars)
        }
        let spend = ClaudeCodeLocalProvider.spend(from: [
            response("a", "2026-11-05T09:00:00Z", 3),  // 1 AM local today
            response("a", "2026-11-05T09:00:00Z", 3),  // the same response in a second file
            response("b", "2026-11-05T07:00:00Z", 5),  // 11 PM local yesterday
            response("c", "2026-11-01T06:00:00Z", 100), // October 31 local
            response("d", "2026-11-05T10:00:00Z", nil, model: "claude-next-9"),
        ], now: now, calendar: calendar)
        #expect(spend.today == 3)
        #expect(spend.monthToDate == 8)
        #expect(spend.isUTCDay == false)
        #expect(spend.unpricedModels == ["claude-next-9"])
        #expect(spend.resetsAt == (try! Date("2026-11-06T08:00:00Z", strategy: .iso8601)))
    }
}

@Suite("Discount")
struct DiscountTests {
    @Test func theDiscountComesOffBothAmountsAndTheThresholdsSeeTheResult() {
        var state = AccountState(account: Account(kind: .anthropicAPI, spendWarning: 90, discountPercent: 15))
        state.reading = Reading(spend: Spend(today: 100, monthToDate: 1000, resetsAt: .now, isUTCDay: true))
        #expect(state.spend?.today == 85)
        #expect(state.spend?.monthToDate == 850)
        #expect(state.account.spendLevel(state.spend!.today) == .normal)
    }

    @Test func aDiscountOutsideZeroToOneHundredIsClamped() {
        #expect(Account(kind: .claudeCodeLocal, discountPercent: 250).discounted(40) == 0)
        #expect(Account(kind: .claudeCodeLocal, discountPercent: -10).discounted(40) == 40)
        #expect(Account(kind: .claudeCodeLocal).discounted(40) == 40)
    }

    @Test func aNewDiscountKeepsTheReading() {
        let account = Account(kind: .claudeCodeLocal)
        var changed = account
        changed.discountPercent = 20
        #expect(account.readsTheSame(as: changed))
    }
}
