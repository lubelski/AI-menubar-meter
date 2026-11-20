import Foundation

/// The company behind an account. Its logo labels that account's tanks.
public enum Brand: Sendable, Equatable {
    case anthropic
    case openAI
    case openRouter

    public var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }
}

/// A kind of account AI Meter can read. To add a kind, add a case here, a provider
/// in `Providers`, and a form in the Accounts settings.
public enum AccountKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A Claude subscription (Pro, Max, Team).
    case claude
    /// A ChatGPT subscription, as used by Codex.
    case codex
    /// An Anthropic API organization, read with an Admin key.
    case anthropicAPI
    /// OpenRouter's prepaid credit balance, read with a Management API key.
    case openRouter

    public var id: Self { self }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "OpenAI"
        case .anthropicAPI: "Anthropic API"
        case .openRouter: "OpenRouter"
        }
    }

    public var brand: Brand {
        switch self {
        case .claude, .anthropicAPI: .anthropic
        case .codex: .openAI
        case .openRouter: .openRouter
        }
    }

    /// The web page that shows the same numbers in full.
    public var usagePage: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/settings/usage?tab=overview")!
        case .anthropicAPI: URL(string: "https://platform.claude.com/cost")!
        case .openRouter: URL(string: "https://openrouter.ai/settings/credits")!
        }
    }

    /// Ways to sign in, with the default first.
    public var credentialSources: [CredentialSource] {
        switch self {
        case .claude, .codex: OAuthClient.for(self) == nil ? [.cli, .pasted] : [.cli, .oauth, .pasted]
        case .anthropicAPI, .openRouter: [.pasted]
        }
    }

    /// Tanks every account of this kind has. The menu bar keeps a slot for each of
    /// them before the first reading arrives, so the icon doesn't change width.
    public var expectedTanks: [Tank.Kind] {
        switch self {
        case .claude, .codex: [.session, .weekly]
        case .anthropicAPI, .openRouter: [.pool]
        }
    }
}

public enum CredentialSource: String, Codable, Identifiable, Sendable {
    /// The login that the service's command-line tool keeps on this Mac.
    case cli
    /// A token or key pasted into Settings and stored in AI Meter's Keychain item.
    case pasted
    /// A login AI Meter obtained itself through the service's browser sign-in. AI Meter
    /// keeps it in its own Keychain item and refreshes it, since no other program uses it.
    case oauth

    public var id: Self { self }
}

/// One account the user has added. The list of accounts is stored in `UserDefaults`.
/// Secrets are not part of it. They live in the Keychain under `secretKey`.
public struct Account: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: AccountKind
    /// The user's label, shown in the panel and in Settings.
    public var name: String
    /// Hidden accounts stay configured but leave the menu bar and the panel.
    public var isVisible: Bool
    public var credential: CredentialSource
    /// Codex only: folder that holds `auth.json`. `nil` means the default folder.
    public var codexHome: String?
    /// Codex with a pasted token only: the workspace to read, for Team and Enterprise.
    public var chatGPTAccountID: String?
    /// Anthropic API, and OpenRouter keys without a limit: the monthly budget that spend is measured against.
    public var monthlyBudget: Double?
    /// OpenRouter only: the hash of the API key to show. `nil` shows the account's credit balance.
    public var openRouterKeyHash: String?

    public init(
        id: UUID = UUID(),
        kind: AccountKind,
        name: String? = nil,
        isVisible: Bool = true,
        credential: CredentialSource? = nil,
        codexHome: String? = nil,
        chatGPTAccountID: String? = nil,
        monthlyBudget: Double? = nil,
        openRouterKeyHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.isVisible = isVisible
        self.credential = credential ?? kind.credentialSources[0]
        self.codexHome = codexHome
        self.chatGPTAccountID = chatGPTAccountID
        self.monthlyBudget = monthlyBudget ?? (kind == .anthropicAPI ? Self.defaultMonthlyBudget : nil)
        self.openRouterKeyHash = openRouterKeyHash
    }

    public static let defaultMonthlyBudget = 100.0

    /// Keychain account name for this account's pasted secret.
    public var secretKey: String { "account.\(id.uuidString)" }

    /// The folder Codex keeps its login in when the user hasn't chosen one.
    public static var defaultCodexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path(percentEncoded: false)
    }

    public var resolvedCodexHome: String { codexHome ?? Self.defaultCodexHome }

    /// True when both values read the same numbers from the same place, so a reading
    /// fetched for one is still valid for the other. A rename or a visibility change keeps it true.
    public func readsTheSame(as other: Account) -> Bool {
        var a = self, b = other
        a.name = ""; b.name = ""
        a.isVisible = true; b.isVisible = true
        return a == b
    }
}
