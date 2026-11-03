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
