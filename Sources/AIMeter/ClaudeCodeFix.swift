import AIMeterCore
import AppKit
import SwiftUI

/// Explains a Claude Code login problem and offers the step that fixes it.
struct ClaudeCodeFix: View {
    let store: UsageStore
    let account: Account
    let issue: ClaudeCodeIssue

    @State private var terminalFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(explanation))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isWaitingForClaudeCode {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Claude Code…")
                    Spacer()
                    Button("Cancel") { store.stopWaitingForClaudeCode() }
                }
            } else {
                HStack(spacing: 8) {
                    actions
                }
                .disabled(store.isRefreshing)
            }

            if terminalFailed {
                Text("Couldn't open Terminal. Run `claude` in a terminal yourself, then click Try Again.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanation: String {
        switch issue {
        case .refreshFailed:
            "Claude Code's sign-in token expired, and an automatic refresh didn't renew it. Starting Claude Code once usually fixes this. AI Meter opens it in Terminal. When it has started, type `/exit`."
        case .loginExpired:
            "Your Claude Code login has expired. Sign in again in Terminal. AI Meter reconnects when the sign-in finishes."
        case .signedOut:
            "Claude Code isn't signed in on this Mac. Sign in in Terminal. AI Meter reconnects when the sign-in finishes."
        case .cliNotFound:
            "AI Meter has no usable Claude Code login and can't find the `claude` command to refresh one. Install Claude Code, or switch to an access token."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch issue {
        case .refreshFailed:
            Button("Open Claude Code") { openTerminal([]) }
            Button("Try Again") { Task { await store.retryClaudeCode() } }
        case .loginExpired, .signedOut:
            Button("Sign In…") { openTerminal(["auth", "login"]) }
            Button("Check Again") { Task { await store.retryClaudeCode() } }
        case .cliNotFound:
            Button("Use Access Token") {
                var changed = account
                changed.credential = .pasted
                store.update(changed)
            }
            Button("Check Again") { Task { await store.retryClaudeCode() } }
        }
    }

    private func openTerminal(_ arguments: [String]) {
        Task {
            await store.waitForClaudeCodeLogin()
            terminalFailed = !(await ClaudeTerminal.run(arguments))
            if terminalFailed { store.stopWaitingForClaudeCode() }
        }
    }
}

/// Opens Terminal and runs the `claude` CLI there, so the user can see and answer its prompts.
enum ClaudeTerminal {
    static func run(_ arguments: [String]) async -> Bool {
        let claude = await ClaudeCodeCLI.shared.path() ?? "claude"
        let command = ([claude] + arguments).map(shellQuoted).joined(separator: " ")
        let script = """
        #!/bin/zsh -l
        rm -f -- "$0"
        clear
        echo "AI Meter is running: claude \(arguments.joined(separator: " "))"
        echo
        \(command)
        echo
        echo "Done. You can close this window. AI Meter picks up the new login on its own."

        """
        // Terminal opens .command files and runs them, without an Automation permission prompt.
        let url = FileManager.default.temporaryDirectory
            .appending(path: "AIMeter-claude-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
