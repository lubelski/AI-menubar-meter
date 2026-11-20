import Foundation

/// One allowance that drains as the account is used: a rate-limit window or a pool of dollars.
public struct Tank: Sendable, Equatable, Identifiable {
    /// Short windows draw thinnest and money pools widest, so the shape alone tells them apart.
    /// `fable` is the weekly limit on the Fable model alone. It draws like `weekly`.
    /// Case order is display order: most specific first, so Fable comes before the all-model weekly limit.
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        case session, fable, weekly, pool

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// "Session", "Weekly", "Fable", "API credit".
    public var title: String
    /// Portion of the allowance consumed, clamped to `0...1`.
    public var used: Double
    public var resetsAt: Date?
    /// Total length of the window, when known. Used to compute pace.
    public var duration: TimeInterval?
    /// The allowance in dollars, for pools.
    public var dollars: Dollars?

    /// A reading has at most one tank of each kind.
    public var id: Kind { kind }

    public init(
        kind: Kind, title: String, used: Double,
        resetsAt: Date? = nil, duration: TimeInterval? = nil, dollars: Dollars? = nil
    ) {
        self.kind = kind
        self.title = title
        self.used = min(max(used, 0), 1)
        self.resetsAt = resetsAt
        self.duration = duration
        self.dollars = dollars
    }

    /// Portion of the allowance left. This is the level the tank draws.
    public var remaining: Double { 1 - used }

    public var level: UsageLevel { UsageLevel(fraction: used) }

    /// How far through the window we are in time (`0...1`), or `nil` if unknown.
    /// Comparing this with `used` tells you whether usage is ahead of an even pace.
    public func elapsedFraction(now: Date = .now) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / duration, 0), 1)
    }
}

/// A dollar-denominated allowance, e.g. the API credit bundled with a Claude plan.
public struct Dollars: Sendable, Equatable {
    public var used: Double
    public var limit: Double

    public init(used: Double, limit: Double) {
        self.used = used
        self.limit = limit
    }

    public var remaining: Double { max(limit - used, 0) }
    public var fraction: Double { limit > 0 ? min(max(used / limit, 0), 1) : 0 }
}

/// A weekly limit restricted to one model (e.g. "Opus only").
public struct ScopedLimit: Sendable, Equatable {
    public var name: String
    public var fraction: Double

    public init(name: String, fraction: Double) {
        self.name = name
        self.fraction = min(max(fraction, 0), 1)
    }
}

/// Everything one fetch returned for one account.
public struct Reading: Sendable, Equatable {
    public var plan: String?
    public var tanks: [Tank]
    public var scoped: [ScopedLimit]

    public init(plan: String? = nil, tanks: [Tank] = [], scoped: [ScopedLimit] = []) {
        self.plan = plan
        self.tanks = tanks.sorted { $0.kind < $1.kind }
        self.scoped = scoped
    }

    public func tank(_ kind: Tank.Kind) -> Tank? {
        tanks.first { $0.kind == kind }
    }
}

/// Severity bucket shared by the menu bar icon and the detail panel.
/// A tank turns orange with 25% left and red with 10% left.
public enum UsageLevel: Sendable, Equatable {
    case normal, warning, critical

    /// `fraction` is the portion used.
    public init(fraction: Double) {
        switch fraction {
        case 0.9...: self = .critical
        case 0.75...: self = .warning
        default: self = .normal
        }
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case notSignedIn
    case sessionExpired
    case keyRejected
    /// The OpenRouter key the account shows was deleted, disabled or has expired.
    case keyNotFound
    case claudeCode(ClaudeCodeIssue)
    case rateLimited
    case network(String)
    case unexpectedResponse

    /// Errors the user has to fix (as opposed to ones that clear up on their own).
    public var needsAttention: Bool {
        switch self {
        case .notSignedIn, .sessionExpired, .keyRejected, .keyNotFound, .claudeCode: true
        case .rateLimited, .network, .unexpectedResponse: false
        }
    }

    /// The Claude Code problem behind this error, if there is one. The UI shows a fix for it.
    public var claudeCodeIssue: ClaudeCodeIssue? {
        if case .claudeCode(let issue) = self { issue } else { nil }
    }

    public var message: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .sessionExpired: "Sign-in expired"
        case .keyRejected: "Key was rejected"
        case .keyNotFound: "Key not found"
        case .claudeCode(.signedOut): "Claude Code is signed out"
        case .claudeCode(.loginExpired): "Claude Code login expired"
        case .claudeCode(.refreshFailed): "Sign-in needs a refresh"
        case .claudeCode(.cliNotFound): "Can't find Claude Code"
        case .rateLimited: "Rate limited"
        case .network(let detail): detail
        case .unexpectedResponse: "Unexpected response"
        }
    }
}
