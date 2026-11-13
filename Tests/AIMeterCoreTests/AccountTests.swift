import Foundation
import Testing
@testable import AIMeterCore

/// Keeps secrets in memory so tests never touch the Keychain.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    func read(_ key: String) -> String? {
        lock.withLock { values[key] }
    }

    @discardableResult
    func write(_ value: String, for key: String) -> Bool {
        lock.withLock { values[key] = value.isEmpty ? nil : value }
        return true
    }
}

/// Keeps settings in memory so tests never write preference files.
final class MemorySettings: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private func reading(_ used: Double) -> Reading {
    Reading(tanks: [Tank(kind: .session, title: "Session", used: used)])
}

@Suite("Account state")
struct AccountStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func state(readAgo: TimeInterval?, error: ProviderError?) -> AccountState {
        var state = AccountState(account: Account(kind: .claude))
        if let readAgo {
            state.reading = reading(0.4)
            state.readAt = now.addingTimeInterval(-readAgo)
        }
        state.error = error
        return state
    }

    @Test func waitsBeforeTheFirstAttempt() {
        #expect(state(readAgo: nil, error: nil).condition(now: now, staleAfter: 660) == .waiting)
    }

    @Test func isUnavailableWhenNothingWasEverRead() {
        #expect(state(readAgo: nil, error: .network("Offline")).condition(now: now, staleAfter: 660) == .unavailable)
    }

    @Test func oneFailedRefreshKeepsTheReadingLive() {
        #expect(state(readAgo: 300, error: .rateLimited).condition(now: now, staleAfter: 660) == .live)
    }

    @Test func anOldReadingIsStale() {
        #expect(state(readAgo: 700, error: .rateLimited).condition(now: now, staleAfter: 660) == .stale)
        #expect(state(readAgo: 700, error: nil).condition(now: now, staleAfter: 660) == .stale)
    }

    @Test func anErrorTheUserMustFixIsStaleAtOnce() {
        #expect(state(readAgo: 10, error: .sessionExpired).condition(now: now, staleAfter: 660) == .stale)
    }

    @Test func slotsHoldAPlaceForEveryExpectedTank() {
        var state = AccountState(account: Account(kind: .claude))
        #expect(state.slots.map(\.kind) == [.session, .weekly])
        #expect(state.slots.allSatisfy { $0.tank == nil })

        state.reading = Reading(tanks: [
            Tank(kind: .pool, title: "API credit", used: 0.5),
            Tank(kind: .session, title: "Session", used: 0.1),
        ])
        #expect(state.slots.map(\.kind) == [.session, .weekly, .pool])
        #expect(state.slots.map { $0.tank != nil } == [true, false, true])
    }

    @Test func aFableTankSitsBetweenSessionAndWeekly() {
        var state = AccountState(account: Account(kind: .claude))
        state.reading = Reading(tanks: [
            Tank(kind: .pool, title: "API credit", used: 0.5),
            Tank(kind: .fable, title: "Fable", used: 0.8),
            Tank(kind: .weekly, title: "Weekly", used: 0.6),
        ])
        #expect(state.slots.map(\.kind) == [.session, .fable, .weekly, .pool])
    }
}

@Suite("Account list")
struct AccountRepositoryTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test func aFreshInstallAddsOnlyTheLoginsItFinds() {
        let codexAuth = URL(fileURLWithPath: Account.defaultCodexHome).appending(path: "auth.json").path(percentEncoded: false)
        let repository = AccountRepository(defaults: MemorySettings(), secrets: MemorySecrets(), home: home) {
            $0 == codexAuth
        }
        #expect(repository.load().map(\.kind) == [.codex])
    }

    @Test func aFreshInstallWithNoLoginsStartsEmpty() {
        let repository = AccountRepository(defaults: MemorySettings(), secrets: MemorySecrets(), home: home) { _ in false }
        #expect(repository.load().isEmpty)
    }

    @Test func migratesTheSingleAccountSettings() throws {
        let defaults = MemorySettings()
        defaults.set("token", forKey: "auth.claude.source")
        defaults.set("codexCLI", forKey: "auth.openai.source")
        defaults.set("/tmp/other-codex", forKey: "auth.openai.codexHome")
        defaults.set(false, forKey: "show.openAI")
        defaults.set("adminKey", forKey: "auth.credit.source")
        defaults.set(250.0, forKey: "auth.credit.monthlyBudget")
        let secrets = MemorySecrets(["claudeToken": "oat", "anthropicAdminKey": "admin"])
        let repository = AccountRepository(defaults: defaults, secrets: secrets, home: home) { _ in false }

        let accounts = repository.load()
        #expect(accounts.map(\.kind) == [.claude, .codex, .anthropicAPI])

        #expect(accounts[0].credential == .pasted)
        #expect(secrets.read(accounts[0].secretKey) == "oat")
        #expect(secrets.read("claudeToken") == nil)

        #expect(accounts[1].credential == .cli)
        #expect(accounts[1].codexHome == "/tmp/other-codex")
        #expect(accounts[1].isVisible == false)

        #expect(accounts[2].monthlyBudget == 250)
        #expect(secrets.read(accounts[2].secretKey) == "admin")
    }

    @Test func savedAccountsLoadBackInOrder() {
        let repository = AccountRepository(defaults: MemorySettings(), secrets: MemorySecrets(), home: home) { _ in true }
        let accounts = [
            Account(kind: .codex, name: "Work"),
            Account(kind: .codex, name: "Personal", codexHome: "/tmp/personal"),
            Account(kind: .codex, name: "Side project", credential: .pasted, chatGPTAccountID: "acct_1"),
        ]
        repository.save(accounts)
        #expect(repository.load() == accounts)
    }

    @Test func anAccountOfAnUnknownKindIsSkipped() {
        let defaults = MemorySettings()
        let json = """
        [{"id":"\(UUID().uuidString)","kind":"gemini","name":"Gemini","isVisible":true,"credential":"cli"},
         {"id":"\(UUID().uuidString)","kind":"codex","name":"OpenAI","isVisible":true,"credential":"cli"}]
        """
        defaults.set(Data(json.utf8), forKey: "accounts")
        let repository = AccountRepository(defaults: defaults, secrets: MemorySecrets(), home: home) { _ in false }
        #expect(repository.load().map(\.name) == ["OpenAI"])
    }

    @Test func aRenameReadsTheSameButANewFolderDoesNot() {
        let account = Account(kind: .codex)
        var renamed = account
        renamed.name = "Work"
        renamed.isVisible = false
        #expect(account.readsTheSame(as: renamed))

        var moved = account
        moved.codexHome = "/tmp/other"
        #expect(!account.readsTheSame(as: moved))
    }
}

@Suite("Usage store")
@MainActor
struct UsageStoreTests {
    private func store(
        _ accounts: [Account], secrets: MemorySecrets = MemorySecrets(), fetch: @escaping UsageStore.Fetch
    ) -> UsageStore {
        let repository = AccountRepository(defaults: MemorySettings(), secrets: secrets,
                                           home: URL(fileURLWithPath: "/Users/tester")) { _ in false }
        repository.save(accounts)
        return UsageStore(repository: repository, fetch: fetch)
    }

    @Test func readsEveryAccountOfTheSameKind() async {
        let accounts = [Account(kind: .codex, name: "A"), Account(kind: .codex, name: "B"), Account(kind: .codex, name: "C")]
        let used = [accounts[0].id: 0.1, accounts[1].id: 0.5, accounts[2].id: 0.9]
        let store = store(accounts) { account in .success(reading(used[account.id]!)) }

        await store.refresh()

        #expect(store.states.map(\.account.name) == ["A", "B", "C"])
        #expect(store.states.map { $0.reading?.tank(.session)?.used } == [0.1, 0.5, 0.9])
        #expect(store.states.allSatisfy { store.condition(of: $0) == .live })
    }

    @Test func aFailureKeepsTheLastReadingAndRecordsTheError() async {
        let fails = Flag()
        let store = store([Account(kind: .claude)]) { _ in
            fails.isSet ? .failure(.network("Offline")) : .success(reading(0.3))
        }
        await store.refresh()
        fails.set()
        await store.refresh()

        let state = store.states[0]
        #expect(state.reading == reading(0.3))
        #expect(state.error == .network("Offline"))
        #expect(store.condition(of: state) == .live)
        #expect(store.condition(of: state, now: .now.addingTimeInterval(store.staleAfter + 1)) == .stale)
    }

    @Test func oneAccountFailingDoesNotAffectAnother() async {
        let accounts = [Account(kind: .claude), Account(kind: .codex)]
        let store = store(accounts) { account in
            account.kind == .claude ? .failure(.notSignedIn) : .success(reading(0.2))
        }
        await store.refresh()
        #expect(store.condition(of: store.states[0]) == .unavailable)
        #expect(store.condition(of: store.states[1]) == .live)
    }

    @Test func changingTheLoginDiscardsTheReadingButARenameKeepsIt() async {
        let store = store([Account(kind: .codex)]) { _ in .success(reading(0.3)) }
        await store.refresh()

        var account = store.accounts[0]
        account.name = "Work"
        store.update(account)
        #expect(store.states[0].reading != nil)

        account.codexHome = "/tmp/other"
        store.update(account)
        #expect(store.states[0].reading == nil)
    }

    @Test func addsNamesAndRemovesAccounts() async {
        let secrets = MemorySecrets()
        let store = store([Account(kind: .codex)], secrets: secrets) { _ in .success(reading(0.3)) }

        let second = store.addAccount(.codex)
        #expect(store.accounts.map(\.name) == ["OpenAI", "OpenAI 2"])

        store.setSecret("token", for: second)
        #expect(secrets.read(second.secretKey) == "token")
        store.removeAccount(second.id)
        #expect(secrets.read(second.secretKey) == nil)
        #expect(store.accounts.map(\.name) == ["OpenAI"])
    }

    @Test func movesAccounts() {
        let store = store(["A", "B", "C", "D"].map { Account(kind: .codex, name: $0) }) { _ in .success(reading(0)) }
        store.moveAccounts(fromOffsets: [0], toOffset: 3)
        #expect(store.accounts.map(\.name) == ["B", "C", "A", "D"])
        store.moveAccounts(fromOffsets: [3], toOffset: 0)
        #expect(store.accounts.map(\.name) == ["D", "B", "C", "A"])
    }

    @Test func hiddenAccountsLeaveTheVisibleList() {
        var hidden = Account(kind: .claude)
        hidden.isVisible = false
        let store = store([hidden, Account(kind: .codex)]) { _ in .success(reading(0)) }
        #expect(store.visibleStates.map(\.account.kind) == [.codex])
    }
}

/// A switch a test can flip from outside a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
