import Foundation
import Security

public enum ClaudeAuthSource: String, CaseIterable, Identifiable, Sendable {
    /// The login Claude Code keeps in the Keychain.
    case claudeCode
    /// An OAuth access token pasted into Settings.
    case token

    public var id: Self { self }
}

public enum OpenAIAuthSource: String, CaseIterable, Identifiable, Sendable {
    /// The login the Codex CLI keeps in `auth.json`.
    case codexCLI
    /// A ChatGPT access token pasted into Settings.
    case token

    public var id: Self { self }
}

public enum CreditSource: String, CaseIterable, Identifiable, Sendable {
    /// The API credit bundled with the Claude plan, read with the Claude sign-in.
    case claudePlan
    /// Month-to-date spend from the Anthropic Admin API, measured against a budget.
    case adminKey

    public var id: Self { self }
}

/// Secrets live in AI Meter's own Keychain items, never in `UserDefaults`.
public enum Secret: String, Sendable {
    case claudeToken
    case openAIToken
    case anthropicAdminKey
}

/// `UserDefaults` keys for non-secret account settings.
public enum AuthPreferences {
    public static let claudeSource = "auth.claude.source"
    public static let openAISource = "auth.openai.source"
    public static let codexHome = "auth.openai.codexHome"
    public static let openAIAccountID = "auth.openai.accountID"
    public static let creditSource = "auth.credit.source"
    public static let monthlyBudget = "auth.credit.monthlyBudget"

    public static var defaultCodexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path(percentEncoded: false)
    }
}

/// A snapshot of every account setting, taken at the start of each refresh.
public struct AuthConfig: Sendable {
    public var claudeSource: ClaudeAuthSource
    public var claudeToken: String?
    public var openAISource: OpenAIAuthSource
    public var codexHome: URL
    public var openAIToken: String?
    public var openAIAccountID: String?
    public var creditSource: CreditSource
    public var adminKey: String?
    public var monthlyBudget: Double

    public static func load(from defaults: UserDefaults = .standard) -> AuthConfig {
        let claudeSource = defaults.string(forKey: AuthPreferences.claudeSource)
            .flatMap(ClaudeAuthSource.init) ?? .claudeCode
        let openAISource = defaults.string(forKey: AuthPreferences.openAISource)
            .flatMap(OpenAIAuthSource.init) ?? .codexCLI
        let creditSource = defaults.string(forKey: AuthPreferences.creditSource)
            .flatMap(CreditSource.init) ?? .claudePlan

        // Only touch the Keychain for secrets that are actually in use.
        return AuthConfig(
            claudeSource: claudeSource,
            claudeToken: claudeSource == .token ? Keychain.read(.claudeToken) : nil,
            openAISource: openAISource,
            codexHome: URL(fileURLWithPath: defaults.string(forKey: AuthPreferences.codexHome)
                ?? AuthPreferences.defaultCodexHome),
            openAIToken: openAISource == .token ? Keychain.read(.openAIToken) : nil,
            openAIAccountID: defaults.string(forKey: AuthPreferences.openAIAccountID).flatMap { $0.isEmpty ? nil : $0 },
            creditSource: creditSource,
            adminKey: creditSource == .adminKey ? Keychain.read(.anthropicAdminKey) : nil,
            monthlyBudget: defaults.object(forKey: AuthPreferences.monthlyBudget) as? Double ?? 100
        )
    }
}

/// Minimal generic-password wrapper scoped to AI Meter's service name.
public enum Keychain {
    private static let service = "dev.lubelski.AIMeter"

    private static func query(_ secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
        ]
    }

    public static func read(_ secret: Secret) -> String? {
        var query = query(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores `value`, or deletes the item when `value` is empty.
    @discardableResult
    public static func write(_ value: String, for secret: Secret) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(secret) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(secret)
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
