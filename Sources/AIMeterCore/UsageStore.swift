import Foundation
import Observation

/// The latest result from one provider. A failed refresh keeps the previous
/// value so the UI can show slightly stale numbers rather than nothing.
public struct ProviderStatus<Value: Sendable>: Sendable {
    public var value: Value?
    public var error: ProviderError?
    public var updatedAt: Date?

    public var isConnected: Bool { updatedAt != nil && error == nil }
}

/// One thermometer in the menu bar.
public struct UsageGauge: Sendable, Equatable {
    /// Short windows draw thinnest and money pools widest, so the shape alone tells them apart.
    public enum Kind: Sendable, Equatable {
        case session, weekly, pool
    }

    public var label: String
    public var kind: Kind
    public var fraction: Double?

    public init(label: String, kind: Kind, fraction: Double?) {
        self.label = label
        self.kind = kind
        self.fraction = fraction
    }

    public var level: UsageLevel { UsageLevel(fraction: fraction ?? 0) }
}

@MainActor
@Observable
public final class UsageStore {
    public private(set) var claude = ProviderStatus<ClaudeUsage>()
    public private(set) var codex = ProviderStatus<CodexUsage>()
    /// `value == nil` with no error means the account has no API credit.
    public private(set) var credit = ProviderStatus<CreditUsage>()
    public private(set) var isRefreshing = false

    @ObservationIgnored private var interval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = false

    public init(interval: Duration = .seconds(300)) {
        self.interval = interval
    }

    /// Menu bar gauges for one service, as used fractions.
    public func gauges(for service: Service) -> [UsageGauge] {
        switch service {
        case .claude:
            [
                UsageGauge(label: "Claude session", kind: .session, fraction: claude.value?.session?.fraction),
                UsageGauge(label: "Claude weekly", kind: .weekly, fraction: claude.value?.weekly?.fraction),
            ]
        case .openAI:
            [
                UsageGauge(label: "OpenAI session", kind: .session, fraction: codex.value?.session?.fraction),
                UsageGauge(label: "OpenAI weekly", kind: .weekly, fraction: codex.value?.weekly?.fraction),
            ]
        case .apiCredit:
            [UsageGauge(label: "API credit", kind: .pool, fraction: credit.value?.fraction)]
        }
    }

    public var lastUpdated: Date? {
        [claude.updatedAt, codex.updatedAt, credit.updatedAt].compactMap(\.self).max()
    }

    // MARK: Polling

    public func start() {
        startPolling(refreshingFirst: true)
    }

    /// Changes the polling cadence without triggering an extra fetch.
    public func setInterval(_ newInterval: Duration) {
        guard newInterval != interval else { return }
        interval = newInterval
        pollTask?.cancel()
        pollTask = nil
        startPolling(refreshingFirst: false)
    }

    private func startPolling(refreshingFirst: Bool) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, interval] in
            if !refreshingFirst {
                try? await Task.sleep(for: interval)
            }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Refreshes when the panel opens, but avoids hammering the endpoints
    /// (Anthropic's rate-limits this one aggressively).
    public func refreshIfStale(olderThan age: TimeInterval = 60) {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < age { return }
        Task { await refresh() }
    }

    // MARK: Refresh

    /// Fetches everything using the current account settings. If called while a
    /// refresh is running (e.g. right after an account change), it runs once more after.
    public func refresh() async {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            pendingRefresh = false
            await fetchAll(config: AuthConfig.load())
        } while pendingRefresh
    }

    private func fetchAll(config: AuthConfig) async {
        async let claudeResult = capture { () async throws(ProviderError) in
            try await ClaudeProvider().fetch(config)
        }
        async let codexResult = capture { () async throws(ProviderError) in
            try await CodexProvider().fetch(config)
        }
        async let adminResult: Result<CreditUsage, ProviderError>? = config.creditSource == .adminKey
            ? capture { () async throws(ProviderError) in try await AnthropicCostProvider().fetch(config) }
            : nil

        let claude = await claudeResult
        Self.apply(claude.map(Optional.some), to: &self.claude)
        Self.apply(await codexResult.map(Optional.some), to: &codex)
        // Plan credit rides along with the Claude response unless an Admin key is configured.
        Self.apply(await adminResult?.map(Optional.some) ?? claude.map(\.credit), to: &credit)
    }

    private static func apply<Value>(_ result: Result<Value?, ProviderError>, to status: inout ProviderStatus<Value>) {
        switch result {
        case .success(let value):
            status = ProviderStatus(value: value, error: nil, updatedAt: .now)
        case .failure(let error):
            status.error = error
        }
    }
}

private func capture<Value>(
    _ body: () async throws(ProviderError) -> Value
) async -> Result<Value, ProviderError> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
