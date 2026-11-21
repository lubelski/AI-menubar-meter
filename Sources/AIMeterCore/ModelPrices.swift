import Foundation

/// The token counts of one Claude API response, as Claude Code logs them.
struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    /// Cache writes kept for 5 minutes.
    var cacheWrite5m = 0
    /// Cache writes kept for 1 hour.
    var cacheWrite1h = 0
    /// True for a response made in fast mode, which costs twice as much.
    var isFast = false

    var isEmpty: Bool { input + output + cacheRead + cacheWrite5m + cacheWrite1h == 0 }
}

/// Anthropic's list prices, for turning logged token counts into dollars.
///
/// Prices are in dollars per million tokens and were read from Anthropic's pricing on
/// 2026-11-03. They need a new entry when a model is released and an edit when a price
/// changes. A model with no entry is left out of the total and reported by name.
enum ModelPrices {
    struct Price: Equatable, Sendable {
        var input: Double
        var output: Double
        /// What a cache read costs, as a multiple of `input`.
        var cacheRead: Double = 0.1
    }

    /// Keyed by the start of the model id. The longest match wins, so `claude-opus-5-5`
    /// finds its own entry and not `claude-opus-5`, and a dated id such as
    /// `claude-haiku-4-5-20251001` finds `claude-haiku-4-5`.
    private static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-2", Price(input: 8, output: 40, cacheRead: 0.025)),
        ("claude-mythos-5-2", Price(input: 8, output: 40, cacheRead: 0.025)),
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.025)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.025)),
        ("claude-fable-5", Price(input: 10, output: 50)),
        ("claude-mythos-5", Price(input: 10, output: 50)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.05)),
        ("claude-opus-5", Price(input: 5, output: 25)),
        ("claude-opus-4-8", Price(input: 5, output: 25)),
        ("claude-opus-4-7", Price(input: 5, output: 25)),
        ("claude-opus-4-6", Price(input: 5, output: 25)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.05)),
        ("claude-sonnet-5", Price(input: 2, output: 10)),
        ("claude-sonnet-4-6", Price(input: 3, output: 15)),
        ("claude-haiku-5-5", Price(input: 0.10, output: 0.50)),
        ("claude-haiku-4-5", Price(input: 1, output: 5)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// Claude Haiku 5.5 costs five times as much when the prompt is over 100K tokens.
    private static let haikuLongPrompt = Price(input: 0.50, output: 2.50)
    private static let cacheWrite5m = 1.25
    private static let cacheWrite1h = 2.0
    private static let fast = 2.0

    static func price(for model: String) -> Price? {
        table.first { model.hasPrefix($0.prefix) }?.price
    }

    /// The list price of one response in dollars, or `nil` for a model with no entry.
    static func dollars(for usage: TokenUsage, model: String) -> Double? {
        guard var price = price(for: model) else { return nil }
        let prompt = usage.input + usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h
        if model.hasPrefix("claude-haiku-5-5"), prompt > 100_000 { price = haikuLongPrompt }

        let inputTokens = Double(usage.input)
            + Double(usage.cacheRead) * price.cacheRead
            + Double(usage.cacheWrite5m) * cacheWrite5m
            + Double(usage.cacheWrite1h) * cacheWrite1h
        let dollars = (inputTokens * price.input + Double(usage.output) * price.output) / 1_000_000
        return usage.isFast ? dollars * fast : dollars
    }
}
