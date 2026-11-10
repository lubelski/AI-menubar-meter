import Foundation

/// The part of `UserDefaults` that the account list needs. Tests substitute a dictionary,
/// so they never write preference files.
public protocol SettingsStore {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// Loads and saves the list of accounts.
///
/// The list is a JSON array under one `UserDefaults` key. The first load builds it:
/// from the single-account settings of AI Meter 1.0 when they exist, and otherwise
/// from the command-line logins found on this Mac.
public struct AccountRepository {
    static let key = "accounts"

    private let defaults: any SettingsStore
    private let secrets: any SecretStore
    private let home: URL
    private let fileExists: (String) -> Bool

    public init(
        defaults: any SettingsStore = UserDefaults.standard,
        secrets: any SecretStore = KeychainSecrets(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.home = home
        self.fileExists = fileExists
    }

    public func load() -> [Account] {
        if let data = defaults.object(forKey: Self.key) as? Data,
           let stored = try? JSONDecoder().decode([Lossy<Account>].self, from: data) {
            // An entry this version can't read (a kind added by a newer version) is skipped.
            return stored.compactMap(\.value)
        }
        let accounts = firstAccounts()
        save(accounts)
        return accounts
    }

    public func save(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func secret(for account: Account) -> String? {
        secrets.read(account.secretKey)
    }

    public func setSecret(_ value: String, for account: Account) {
        secrets.write(value, for: account.secretKey)
    }

    // MARK: First load

    /// `UserDefaults` keys and Keychain account names used by AI Meter 1.0.
    private enum Legacy {
        static let claudeSource = "auth.claude.source"
        static let openAISource = "auth.openai.source"
        static let codexHome = "auth.openai.codexHome"
        static let openAIAccountID = "auth.openai.accountID"
        static let creditSource = "auth.credit.source"
        static let monthlyBudget = "auth.credit.monthlyBudget"
        static let showClaude = "show.claude"
        static let showOpenAI = "show.openAI"
        static let showAPICredit = "show.apiCredit"

        static let claudeToken = "claudeToken"
        static let openAIToken = "openAIToken"
        static let adminKey = "anthropicAdminKey"
    }

    private func firstAccounts() -> [Account] {
        var accounts: [Account] = []
        func shown(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

        func string(_ key: String) -> String? { defaults.object(forKey: key) as? String }

        let claudeSource = string(Legacy.claudeSource)
        let hasClaudeCode = fileExists(home.appending(path: ".claude").path(percentEncoded: false))
            || fileExists(home.appending(path: ".claude.json").path(percentEncoded: false))
        if claudeSource != nil || hasClaudeCode {
            let account = Account(kind: .claude, isVisible: shown(Legacy.showClaude),
                                  credential: claudeSource == "token" ? .pasted : .cli)
            if account.credential == .pasted { moveSecret(Legacy.claudeToken, to: account) }
            accounts.append(account)
        }

        let openAISource = string(Legacy.openAISource)
        let chosenHome = string(Legacy.codexHome).flatMap { $0 == Account.defaultCodexHome ? nil : $0 }
        let authFile = URL(fileURLWithPath: chosenHome ?? Account.defaultCodexHome).appending(path: "auth.json")
        if openAISource != nil || fileExists(authFile.path(percentEncoded: false)) {
            let account = Account(
                kind: .codex, isVisible: shown(Legacy.showOpenAI),
                credential: openAISource == "token" ? .pasted : .cli,
                codexHome: chosenHome,
                chatGPTAccountID: string(Legacy.openAIAccountID).flatMap { $0.isEmpty ? nil : $0 })
            if account.credential == .pasted { moveSecret(Legacy.openAIToken, to: account) }
            accounts.append(account)
        }

        // 1.0 showed the plan's API credit as its own item. It is now a tank on the Claude
        // account, so only spend read with an Admin key needs an account of its own.
        if string(Legacy.creditSource) == "adminKey" {
            let account = Account(kind: .anthropicAPI, isVisible: shown(Legacy.showAPICredit),
                                  monthlyBudget: defaults.object(forKey: Legacy.monthlyBudget) as? Double)
            moveSecret(Legacy.adminKey, to: account)
            accounts.append(account)
        }
        return accounts
    }

    private func moveSecret(_ legacyKey: String, to account: Account) {
        guard let value = secrets.read(legacyKey) else { return }
        if secrets.write(value, for: account.secretKey) {
            secrets.write("", for: legacyKey)
        }
    }
}

/// Decodes to nil instead of failing, so one unreadable element doesn't lose the whole array.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
