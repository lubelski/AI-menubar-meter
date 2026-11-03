import Foundation

/// A rate-limit window such as "5-hour session" or "7-day weekly".
public struct UsageWindow: Sendable, Equatable {
    /// Portion of the window's allowance consumed, clamped to `0...1`.
    public var fraction: Double
    public var resetsAt: Date?
    /// Total length of the window, when known. Used to compute pace.
    public var duration: TimeInterval?

    public init(fraction: Double, resetsAt: Date?, duration: TimeInterval?) {
        self.fraction = min(max(fraction, 0), 1)
        self.resetsAt = resetsAt
        self.duration = duration
    }

    /// How far through the window we are in time (`0...1`), or `nil` if unknown.
    /// Comparing this with `fraction` tells you whether usage is ahead of pace.
    public func elapsedFraction(now: Date = .now) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / duration, 0), 1)
    }
}

/// A dollar-denominated allowance, e.g. the API credit bundled with a Claude plan.
public struct CreditUsage: Sendable, Equatable {
    public var used: Double
    public var limit: Double
    public var resetsAt: Date?

    public init(used: Double, limit: Double, resetsAt: Date?) {
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
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

public struct ClaudeUsage: Sendable, Equatable {
    public var plan: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var scopedWeekly: [ScopedLimit]
    public var credit: CreditUsage?
}

public struct CodexUsage: Sendable, Equatable {
    public var plan: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
}

/// Severity bucket shared by the menu bar icon and the detail panel.
public enum UsageLevel: Sendable, Equatable {
    case normal, warning, critical

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
    case rateLimited
    case network(String)
    case unexpectedResponse

    /// Errors the user has to fix (as opposed to ones that clear up on their own).
    public var needsAttention: Bool {
        switch self {
        case .notSignedIn, .sessionExpired, .keyRejected: true
        case .rateLimited, .network, .unexpectedResponse: false
        }
    }

    public var message: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .sessionExpired: "Sign-in expired"
        case .keyRejected: "Key was rejected"
        case .rateLimited: "Rate limited — will retry"
        case .network(let detail): detail
        case .unexpectedResponse: "Unexpected response"
        }
    }
}
