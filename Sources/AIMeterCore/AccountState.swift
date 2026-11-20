import Foundation

/// A place for one tank in the menu bar and the panel. `tank` is nil when the
/// account has no value for it yet.
public struct TankSlot: Sendable, Equatable, Identifiable {
    public var kind: Tank.Kind
    public var tank: Tank?

    public var id: Tank.Kind { kind }
}

/// One account together with the latest result of reading it.
///
/// A failed refresh keeps the previous reading and records the error next to it.
/// `condition` then decides whether that reading still counts as current.
public struct AccountState: Sendable, Equatable, Identifiable {
    public var account: Account
    public var reading: Reading?
    /// When `reading` was fetched.
    public var readAt: Date?
    /// The error from the latest attempt. `nil` after a success.
    public var error: ProviderError?
    /// When the latest attempt finished, whether it succeeded or failed.
    public var attemptedAt: Date?

    public var id: UUID { account.id }

    public init(account: Account) {
        self.account = account
    }

    public enum Condition: Sendable, Equatable {
        /// No attempt has finished yet.
        case waiting
        /// The reading is current.
        case live
        /// There is a reading, but it is too old or the account now needs the user's attention.
        case stale
        /// Every attempt so far has failed, so there is nothing to show.
        case unavailable
    }

    /// - Parameter staleAfter: Age at which a reading stops counting as current. One failed
    ///   refresh stays below it, so a single network error doesn't change the display.
    public func condition(now: Date = .now, staleAfter: TimeInterval) -> Condition {
        guard reading != nil, let readAt else {
            return error == nil ? .waiting : .unavailable
        }
        if let error, error.needsAttention { return .stale }
        return now.timeIntervalSince(readAt) > staleAfter ? .stale : .live
    }

    /// The tanks to draw, in display order: every tank the kind always has, plus any
    /// extra tank in the reading (such as a Claude plan's API credit).
    public var slots: [TankSlot] {
        let tanks = reading?.tanks ?? []
        // A reading that is an amount spent has no tanks, so it leaves no empty slot for one.
        let expected = reading?.spend != nil && tanks.isEmpty ? [] : account.kind.expectedTanks
        let kinds = Set(expected).union(tanks.map(\.kind)).sorted()
        return kinds.map { kind in TankSlot(kind: kind, tank: tanks.first { $0.kind == kind }) }
    }

    /// True when the account shows a spend chip: its kind always does, or its latest reading
    /// is an amount spent, as for an OpenRouter key without a limit.
    public var showsSpend: Bool { account.kind.showsSpend || reading?.spend != nil }

    /// What the account spent, with its discount taken off. The reading holds list prices.
    public var spend: Spend? {
        guard var spend = reading?.spend else { return nil }
        spend.today = account.discounted(spend.today)
        spend.monthToDate = account.discounted(spend.monthToDate)
        return spend
    }

    /// Forgets everything read so far. Used when the account starts reading from a different login.
    mutating func reset() {
        reading = nil
        readAt = nil
        error = nil
        attemptedAt = nil
    }
}
