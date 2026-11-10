import Foundation
import Observation

/// Owns the list of accounts and the latest reading of each one.
///
/// The menu bar icon, the panel, and Settings all read `states`. Settings edits the
/// list through the methods under "Accounts", which save it and refresh when needed.
@MainActor
@Observable
public final class UsageStore {
    public typealias Fetch = @Sendable (Account) async -> Result<Reading, ProviderError>

    /// One entry per account, in the user's order.
    public private(set) var states: [AccountState]
    public private(set) var isRefreshing = false
    /// True while the user signs in to Claude Code in Terminal and AI Meter watches for the new login.
    public private(set) var isWaitingForClaudeCode = false
    /// How often the store polls. A reading older than `staleAfter` counts as stale.
    public private(set) var interval: Duration

    @ObservationIgnored private let repository: AccountRepository
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var claudeCodeWatch: Task<Void, Never>?

    /// - Parameter fetch: Reads one account. Tests pass a stub. The default uses the real providers.
    public init(
        repository: AccountRepository = AccountRepository(),
        interval: Duration = .seconds(300),
        fetch: Fetch? = nil
    ) {
        self.repository = repository
        self.interval = interval
        self.fetch = fetch ?? { account in await Providers.fetch(account, secrets: KeychainSecrets()) }
        self.states = repository.load().map(AccountState.init)
    }

    public var accounts: [Account] { states.map(\.account) }

    /// The accounts shown in the menu bar and the panel.
    public var visibleStates: [AccountState] { states.filter(\.account.isVisible) }

    public func state(for id: Account.ID) -> AccountState? {
        states.first { $0.id == id }
    }

    /// Two missed polls, plus a minute of slack for a slow fetch.
    public var staleAfter: TimeInterval {
        2 * TimeInterval(interval.components.seconds) + 60
    }

    public func condition(of state: AccountState, now: Date = .now) -> AccountState.Condition {
        state.condition(now: now, staleAfter: staleAfter)
    }

    public var lastUpdated: Date? {
        states.compactMap(\.readAt).max()
    }

    // MARK: Accounts

    @discardableResult
    public func addAccount(_ kind: AccountKind) -> Account {
        // "OpenAI", then "OpenAI 2", so two accounts of one kind can be told apart.
        let count = states.count { $0.account.kind == kind }
        let account = Account(kind: kind, name: count == 0 ? kind.title : "\(kind.title) \(count + 1)")
        states.append(AccountState(account: account))
        save()
        refreshSoon()
        return account
    }

    /// Replaces the stored account that has the same id. A change to how the account
    /// signs in discards its reading, because that reading came from a different login.
    public func update(_ account: Account) {
        guard let index = states.firstIndex(where: { $0.id == account.id }),
              states[index].account != account else { return }
        let readsTheSame = states[index].account.readsTheSame(as: account)
        states[index].account = account
        save()
        if !readsTheSame {
            states[index].reset()
            refreshSoon()
        }
    }

    public func removeAccount(_ id: Account.ID) {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return }
        repository.setSecret("", for: states[index].account)
        states.remove(at: index)
        save()
    }

    public func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { states[$0] }
        let insertAt = destination - source.count { $0 < destination }
        for index in source.reversed() { states.remove(at: index) }
        states.insert(contentsOf: moving, at: insertAt)
        save()
    }

    public func secret(for account: Account) -> String {
        repository.secret(for: account) ?? ""
    }

    /// Stores a pasted token or key, then reads the account again with it.
    public func setSecret(_ value: String, for account: Account) {
        repository.setSecret(value, for: account)
        guard let index = states.firstIndex(where: { $0.id == account.id }) else { return }
        states[index].reset()
        refreshSoon()
    }

    private func save() {
        repository.save(accounts)
    }

    private func refreshSoon() {
        Task { await refresh() }
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
        let attempted = states.compactMap(\.attemptedAt).max()
        if let attempted, Date.now.timeIntervalSince(attempted) < age { return }
        refreshSoon()
    }

    // MARK: Refresh

    /// Reads every account. If called while a refresh is running (e.g. right after
    /// an account change), it runs once more after.
    public func refresh() async {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            pendingRefresh = false
            await fetchAll()
        } while pendingRefresh
    }

    private func fetchAll() async {
        let accounts = self.accounts
        let fetch = self.fetch
        let results = await withTaskGroup(of: (Account, Result<Reading, ProviderError>).self) { group in
            for account in accounts {
                group.addTask { (account, await fetch(account)) }
            }
            var results: [(Account, Result<Reading, ProviderError>)] = []
            for await result in group { results.append(result) }
            return results
        }

        let now = Date.now
        for (account, result) in results {
            // Skip an account that was removed, or pointed at a different login, during the fetch.
            guard let index = states.firstIndex(where: { $0.id == account.id }),
                  states[index].account.readsTheSame(as: account) else { continue }
            states[index].attemptedAt = now
            switch result {
            case .success(let reading):
                states[index].reading = reading
                states[index].readAt = now
                states[index].error = nil
            case .failure(let error):
                states[index].error = error
            }
        }
    }

    // MARK: Claude Code login

    /// Asks the Claude Code CLI to refresh its login right away, then refreshes.
    public func retryClaudeCode() async {
        await ClaudeCodeCLI.shared.allowImmediateNudge()
        await refresh()
    }

    /// Watches the Claude Code login while the user runs Claude Code in Terminal.
    /// Refreshes as soon as a new, unexpired token appears, or when `timeout` runs out.
    /// Call it before opening Terminal: it records the current token before it returns,
    /// so a refresh that happens right away still counts as new.
    public func waitForClaudeCodeLogin(timeout: Duration = .seconds(300)) async {
        claudeCodeWatch?.cancel()
        isWaitingForClaudeCode = true
        let original = await ClaudeCodeLogin.read()?.accessToken
        claudeCodeWatch = Task { [weak self] in
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                if let login = await ClaudeCodeLogin.read(), login.isUsable(), login.accessToken != original {
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isWaitingForClaudeCode = false
            await self.retryClaudeCode()
        }
    }

    public func stopWaitingForClaudeCode() {
        claudeCodeWatch?.cancel()
        claudeCodeWatch = nil
        isWaitingForClaudeCode = false
    }
}
