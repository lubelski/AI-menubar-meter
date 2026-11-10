import AIMeterCore
import AppKit
import SwiftUI

/// Mail-style accounts pane: the accounts on the left, the selected one's settings on the right.
/// The list holds any number of accounts of each kind. Drag a row to reorder the menu bar.
struct AccountsSettingsView: View {
    let store: UsageStore
    @State private var selection: Account.ID?
    @State private var isConfirmingRemoval = false

    private var selected: AccountState? {
        selection.flatMap(store.state(for:))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // A bordered list (as in Mail's Accounts pane) rather than a sidebar, so it
                // doesn't extend under the toolbar and change how the tab bar looks.
                List(selection: $selection) {
                    ForEach(store.states) { state in
                        AccountRow(state: state, connection: Connection(state, store: store))
                            .tag(state.id)
                    }
                    .onMove { store.moveAccounts(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered)

                HStack(spacing: 0) {
                    Menu {
                        ForEach(AccountKind.allCases) { kind in
                            Button(kind.title) { selection = store.addAccount(kind).id }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an account")

                    Button {
                        isConfirmingRemoval = true
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    .help("Remove the selected account")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
            .frame(width: 200)
            .padding([.leading, .vertical], 20)

            Group {
                if let selected {
                    AccountForm(store: store, state: selected)
                        // Fields keep local text while editing. A new identity resets them per account.
                        .id(selected.id)
                } else {
                    ContentUnavailableView(
                        store.states.isEmpty ? "No Accounts" : "No Account Selected",
                        systemImage: "person.crop.circle",
                        description: Text(store.states.isEmpty ? "Click + to add one." : ""))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = selection ?? store.states.first?.id }
        .confirmationDialog(
            "Remove “\(selected?.account.name ?? "")”?", isPresented: $isConfirmingRemoval
        ) {
            Button("Remove", role: .destructive) {
                guard let id = selection else { return }
                store.removeAccount(id)
                selection = store.states.first?.id
            }
        } message: {
            Text("AI Meter forgets this account and deletes any token stored for it. The service's own login is not affected.")
        }
    }
}

// MARK: - Connection state

/// What the list and the status section show for one account.
private struct Connection {
    var text: String
    var color: Color

    @MainActor
    init(_ state: AccountState, store: UsageStore) {
        if let error = state.error {
            text = error.message
            color = error.needsAttention ? .red : .orange
        } else if state.readAt != nil {
            text = "Connected"
            color = .green
        } else {
            text = store.isRefreshing ? "Checking…" : "Not checked"
            color = .secondary
        }
    }
}

private struct AccountRow: View {
    let state: AccountState
    let connection: Connection

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: BrandMark.image(state.account.kind.brand, size: 14))
                .frame(width: 18)
                .opacity(state.account.isVisible ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.account.name)
                Text(state.account.isVisible ? connection.text : "Hidden")
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

// MARK: - Form

/// Settings for one account: its label, how it signs in, and whether that works.
private struct AccountForm: View {
    let store: UsageStore
    let state: AccountState

    private var account: Account { state.account }

    /// A binding that saves each change to the store.
    private func binding<Value>(_ keyPath: WritableKeyPath<Account, Value>) -> Binding<Value> {
        Binding {
            account[keyPath: keyPath]
        } set: { value in
            var changed = account
            changed[keyPath: keyPath] = value
            store.update(changed)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name))
                Toggle("Show in menu bar and panel", isOn: binding(\.isVisible))
            }

            Section {
                signIn
            } footer: {
                SettingsFootnote(signInNote)
            }

            Section {
                let connection = Connection(state, store: store)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(connection.color).frame(width: 7, height: 7)
                        Text(connection.text)
                        Button("Check Now") { Task { await store.refresh() } }
                            .disabled(store.isRefreshing)
                            .padding(.leading, 6)
                    }
                }
                if let issue = state.error?.claudeCodeIssue {
                    ClaudeCodeFix(store: store, account: account, issue: issue)
                        .font(.callout)
                }
                if let plan = state.reading?.plan {
                    LabeledContent("Plan", value: plan)
                }
                if let readAt = state.readAt {
                    LabeledContent("Last reading") {
                        Text(readAt, format: .relative(presentation: .named))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Sign-in fields

    @ViewBuilder
    private var signIn: some View {
        if account.kind.credentialSources.count > 1 {
            Picker("Sign in with", selection: binding(\.credential)) {
                ForEach(account.kind.credentialSources) { source in
                    Text(title(of: source)).tag(source)
                }
            }
        }
        switch (account.kind, account.credential) {
        case (.claude, .cli):
            LabeledContent("Login", value: "Claude Code, in your Keychain")
        case (.claude, .pasted):
            SecretField(title: "Token", prompt: "sk-ant-oat01-…", store: store, account: account)
        case (.codex, .cli):
            CodexFolderRow(codexHome: binding(\.codexHome))
        case (.codex, .pasted):
            SecretField(title: "Access token", prompt: "eyJ…", store: store, account: account)
            CommittedTextField(title: "Account ID", prompt: "Optional", value: binding(\.chatGPTAccountID))
        case (.anthropicAPI, _):
            SecretField(title: "Admin API key", prompt: "sk-ant-admin01-…", store: store, account: account)
            TextField("Monthly budget", value: binding(\.monthlyBudget),
                      format: .currency(code: "USD").precision(.fractionLength(0)))
        }
    }

    private func title(of source: CredentialSource) -> String {
        switch (account.kind, source) {
        case (.claude, .cli): "Claude Code"
        case (.codex, .cli): "Codex CLI"
        case (_, .cli): "Command-line login"
        case (_, .pasted): "Access token"
        }
    }

    private var signInNote: String {
        switch (account.kind, account.credential) {
        case (.claude, .cli):
            "Uses the login from the `claude` command. When it expires, AI Meter asks Claude Code to refresh it. Claude Code keeps one login per Mac, so a second Claude account needs an access token."
        case (.claude, .pasted):
            "A Claude OAuth access token. It's stored in your Keychain."
        case (.codex, .cli):
            "Uses the ChatGPT login from `codex login`. For a second OpenAI account, sign in with `CODEX_HOME` set to another folder and choose that folder here."
        case (.codex, .pasted):
            "A ChatGPT access token. It's stored in your Keychain. Add the account ID if you're in a Team or Enterprise workspace."
        case (.anthropicAPI, _):
            "Your organization's month-to-date API spend, measured against this budget. Create an Admin key in [Claude Console](https://platform.claude.com) under Settings → Admin keys."
        }
    }
}

// MARK: - Shared pieces

private struct CodexFolderRow: View {
    /// `nil` means the default folder.
    @Binding var codexHome: String?

    var body: some View {
        LabeledContent("Codex folder") {
            HStack {
                Text(((codexHome ?? Account.defaultCodexHome) as NSString).abbreviatingWithTildeInPath)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if codexHome != nil {
                    Button("Use Default") { codexHome = nil }
                }
                Button("Choose…", action: chooseFolder)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true // ~/.codex is hidden
        panel.directoryURL = URL(fileURLWithPath: codexHome ?? Account.defaultCodexHome)
        panel.message = "Choose the folder that contains Codex's auth.json"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        codexHome = path == Account.defaultCodexHome ? nil : path
    }
}

/// A text field that saves on Return or when focus leaves it, so a half-typed
/// value never triggers a fetch. An empty field saves `nil`.
private struct CommittedTextField: View {
    let title: String
    let prompt: String
    @Binding var value: String?

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($isFocused)
            .onAppear { text = value ?? "" }
            .onSubmit(save)
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = trimmed.isEmpty ? nil : trimmed
        if new != value { value = new }
    }
}

/// A secure field backed by the account's Keychain item. Saves on Return or when
/// focus leaves the field. Clearing it removes the item.
private struct SecretField: View {
    let title: String
    let prompt: String
    let store: UsageStore
    let account: Account

    @State private var value = ""
    @State private var saved = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField(title, text: $value, prompt: Text(prompt))
            .focused($isFocused)
            .onAppear {
                value = store.secret(for: account)
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
        saved = value
        store.setSecret(value, for: account)
    }
}
