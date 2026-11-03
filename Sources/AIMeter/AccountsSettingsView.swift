import AIMeterCore
import AppKit
import SwiftUI

/// Mail-style accounts pane: services on the left, the selected one's settings on the right.
struct AccountsSettingsView: View {
    let store: UsageStore
    @State private var selection: Service = .claude

    var body: some View {
        HStack(spacing: 0) {
            // A bordered list (as in Mail's Accounts pane) rather than a sidebar, so it
            // doesn't extend under the toolbar and change how the tab bar looks.
            List(Service.allCases, selection: $selection) { service in
                AccountRow(service: service, connection: Connection(service, store: store))
                    .tag(service)
            }
            .listStyle(.bordered)
            .frame(width: 200)
            .padding([.leading, .vertical], 20)

            Group {
                switch selection {
                case .claude: ClaudeAccountForm(store: store)
                case .openAI: OpenAIAccountForm(store: store)
                case .apiCredit: CreditAccountForm(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Connection state

/// What the sidebar and status section show for one service.
private struct Connection {
    enum State { case connected, failed(ProviderError), checking, unknown }

    var state: State
    var updatedAt: Date?

    @MainActor
    init(_ service: Service, store: UsageStore) {
        let (error, updatedAt): (ProviderError?, Date?) = switch service {
        case .claude: (store.claude.error, store.claude.updatedAt)
        case .openAI: (store.codex.error, store.codex.updatedAt)
        case .apiCredit: (store.credit.error, store.credit.updatedAt)
        }
        self.updatedAt = updatedAt
        if let error {
            state = .failed(error)
        } else if updatedAt != nil {
            state = .connected
        } else {
            state = store.isRefreshing ? .checking : .unknown
        }
    }

    var text: String {
        switch state {
        case .connected: "Connected"
        case .failed(let error): error.message
        case .checking: "Checking…"
        case .unknown: "Not checked"
        }
    }

    var color: Color {
        switch state {
        case .connected: .green
        case .failed(.rateLimited), .failed(.network): .orange
        case .failed: .red
        case .checking, .unknown: .secondary
        }
    }
}

private extension Service {
    var systemImage: String {
        switch self {
        case .claude: "sparkle"
        case .openAI: "hexagon"
        case .apiCredit: "dollarsign.circle"
        }
    }
}

private struct AccountRow: View {
    let service: Service
    let connection: Connection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: service.systemImage)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.title)
                Text(connection.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(connection.color)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Forms

private struct ClaudeAccountForm: View {
    let store: UsageStore
    @AppStorage(AuthPreferences.claudeSource) private var source = ClaudeAuthSource.claudeCode

    var body: some View {
        Form {
            Section {
                Picker("Sign in with", selection: $source) {
                    Text("Claude Code").tag(ClaudeAuthSource.claudeCode)
                    Text("Access token").tag(ClaudeAuthSource.token)
                }
                switch source {
                case .claudeCode:
                    LabeledContent("Login", value: "Claude Code, in your Keychain")
                case .token:
                    SecretField(title: "Token", secret: .claudeToken, prompt: "sk-ant-oat01-…") { refresh() }
                }
            } footer: {
                Footnote(source == .claudeCode
                    ? "Uses the login from the `claude` command. To sign in or switch accounts, run `claude` and then `/login`."
                    : "A Claude OAuth access token. It's stored in your Keychain.")
            }

            StatusSection(store: store, connection: Connection(.claude, store: store)) {
                if let plan = store.claude.value?.plan {
                    LabeledContent("Plan", value: plan)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: source) { refresh() }
    }

    private func refresh() { Task { await store.refresh() } }
}

private struct OpenAIAccountForm: View {
    let store: UsageStore
    @AppStorage(AuthPreferences.openAISource) private var source = OpenAIAuthSource.codexCLI
    @AppStorage(AuthPreferences.codexHome) private var codexHome = AuthPreferences.defaultCodexHome
    @AppStorage(AuthPreferences.openAIAccountID) private var accountID = ""

    var body: some View {
        Form {
            Section {
                Picker("Sign in with", selection: $source) {
                    Text("Codex CLI").tag(OpenAIAuthSource.codexCLI)
                    Text("Access token").tag(OpenAIAuthSource.token)
                }
                switch source {
                case .codexCLI:
                    LabeledContent("Codex folder") {
                        HStack {
                            Text((codexHome as NSString).abbreviatingWithTildeInPath)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    if codexHome != AuthPreferences.defaultCodexHome {
                        LabeledContent("") {
                            Button("Use Default Folder") {
                                codexHome = AuthPreferences.defaultCodexHome
                                refresh()
                            }
                        }
                    }
                case .token:
                    SecretField(title: "Access token", secret: .openAIToken, prompt: "eyJ…") { refresh() }
                    TextField("Account ID", text: $accountID, prompt: Text("Optional"))
                        .onSubmit(refresh)
                }
            } footer: {
                Footnote(source == .codexCLI
                    ? "Uses the ChatGPT login from `codex login`. Run it again to switch accounts."
                    : "A ChatGPT access token. It's stored in your Keychain. Add the account ID if you're in a Team or Enterprise workspace.")
            }

            StatusSection(store: store, connection: Connection(.openAI, store: store)) {
                if let plan = store.codex.value?.plan {
                    LabeledContent("Plan", value: plan)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: source) { refresh() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true // ~/.codex is hidden
        panel.directoryURL = URL(fileURLWithPath: codexHome)
        panel.message = "Choose the folder that contains Codex's auth.json"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexHome = url.path(percentEncoded: false)
        refresh()
    }

    private func refresh() { Task { await store.refresh() } }
}

private struct CreditAccountForm: View {
    let store: UsageStore
    @AppStorage(AuthPreferences.creditSource) private var source = CreditSource.claudePlan
    @AppStorage(AuthPreferences.monthlyBudget) private var budget = 100.0

    private let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: $source) {
                    Text("Claude plan credit").tag(CreditSource.claudePlan)
                    Text("Anthropic Console").tag(CreditSource.adminKey)
                }
                if source == .adminKey {
                    SecretField(title: "Admin API key", secret: .anthropicAdminKey, prompt: "sk-ant-admin01-…") {
                        refresh()
                    }
                    TextField("Monthly budget", value: $budget, format: dollars)
                        .onSubmit(refresh)
                }
            } footer: {
                if source == .claudePlan {
                    Footnote("The API credit included with your Claude plan, read with your Claude sign-in.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Footnote("Your organization's month-to-date API spend, measured against this budget. Create an Admin key in Claude Console under Settings → Admin keys.")
                        Link("Open Claude Console", destination: URL(string: "https://platform.claude.com")!)
                            .font(.caption)
                    }
                }
            }

            StatusSection(store: store, connection: Connection(.apiCredit, store: store)) {
                if let credit = store.credit.value {
                    LabeledContent("Used", value: "\(credit.used.formatted(dollars)) of \(credit.limit.formatted(dollars))")
                } else if store.credit.isConnected {
                    LabeledContent("Used", value: "No API credit on this plan")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: source) { refresh() }
        .onChange(of: budget) { refresh() }
    }

    private func refresh() { Task { await store.refresh() } }
}

// MARK: - Shared pieces

private struct StatusSection<Details: View>: View {
    let store: UsageStore
    let connection: Connection
    @ViewBuilder let details: Details

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(connection.color).frame(width: 7, height: 7)
                    Text(connection.text)
                }
            }
            details
            if let updatedAt = connection.updatedAt {
                LabeledContent("Last checked") {
                    Text(updatedAt, format: .relative(presentation: .named))
                }
            }
            LabeledContent("") {
                Button("Check Now") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
        }
    }
}

/// A secure field backed by AI Meter's Keychain item. Saves on Return or when
/// focus leaves the field; clearing it removes the item.
private struct SecretField: View {
    let title: String
    let secret: Secret
    let prompt: String
    let onSave: () -> Void

    @State private var value = ""
    @State private var saved = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField(title, text: $value, prompt: Text(prompt))
            .focused($isFocused)
            .onAppear {
                value = Keychain.read(secret) ?? ""
                saved = value
            }
            .onSubmit(save)
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            .onDisappear(perform: save)
    }

    private func save() {
        guard value != saved else { return }
        Keychain.write(value, for: secret)
        saved = value
        onSave()
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
