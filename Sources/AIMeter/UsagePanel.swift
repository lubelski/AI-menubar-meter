import AIMeterCore
import SwiftUI

struct UsagePanel: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.visibleStates.isEmpty {
                NoAccounts(hasHiddenAccounts: !store.states.isEmpty)
                Divider()
            }
            ForEach(store.visibleStates) { state in
                AccountSection(store: store, state: state)
                Divider()
            }
            Footer(store: store)
        }
        .padding(16)
        .frame(width: 290)
        // Keep the content at its ideal height, whatever height the window proposes.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { store.refreshIfStale() }
    }
}

// MARK: - Sections

private struct NoAccounts: View {
    let hasHiddenAccounts: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasHiddenAccounts ? "All accounts are hidden" : "No accounts yet")
                .font(.headline)
            Text(hasHiddenAccounts
                ? "Turn on an account's tanks in Settings."
                : "Add a Claude, OpenAI, or Anthropic API account in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings…") {
                dismiss()
                NSApp.activate()
                openSettings()
            }
        }
    }
}

/// One account: its name, its tanks, and anything the user needs to know about the reading.
private struct AccountSection: View {
    let store: UsageStore
    let state: AccountState

    @AppStorage(Preferences.showLogos) private var showLogos = true

    private var account: Account { state.account }

    var body: some View {
        let condition = store.condition(of: state)
        VStack(alignment: .leading, spacing: 10) {
            header

            if let issue = state.error?.claudeCodeIssue {
                // Claude Code problems get their own explanation and buttons.
                ClaudeCodeFix(store: store, account: account, issue: issue)
            } else if let error = state.error, error.needsAttention {
                Text("\(error.message). Check Settings → Accounts.")
                    .foregroundStyle(.secondary)
            }

            if state.reading != nil {
                tanks(condition)
                ForEach(state.reading?.scoped ?? [], id: \.name) { limit in
                    ScopedRow(limit: limit)
                }
            }

            StatusLine(state: state, condition: condition)
        }
        .font(.caption)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if showLogos {
                Image(nsImage: BrandMark.image(account.kind.brand, size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(account.name).font(.headline)
            if let plan = state.reading?.plan {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: account.kind.usagePage) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open \(account.kind.usagePage.host() ?? "usage page")")
        }
    }

    /// Two tanks per row. A third tank, such as a plan's API credit, starts a second row.
    private func tanks(_ condition: AccountState.Condition) -> some View {
        let slots = state.slots
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(stride(from: 0, to: slots.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(slots[start..<min(start + 2, slots.count)]) { slot in
                        TankRow(slot: slot, condition: condition, kind: account.kind)
                    }
                }
            }
        }
    }
}

/// Says why a reading is not current. Shows nothing while everything is fine.
private struct StatusLine: View {
    let state: AccountState
    let condition: AccountState.Condition

    var body: some View {
        switch condition {
        case .live:
            EmptyView()
        case .waiting:
            Text("Loading…").foregroundStyle(.secondary)
        case .stale:
            if let readAt = state.readAt {
                Label {
                    Text("Last reading \(readAt, format: .relative(presentation: .named))\(reason)")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .foregroundStyle(.secondary)
            }
        case .unavailable:
            // Errors that need the user are explained above the tanks.
            if let error = state.error, !error.needsAttention {
                Label("\(error.message). AI Meter will try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The transient error behind a stale reading. Errors that need the user are explained above the tanks.
    private var reason: String {
        guard let error = state.error, !error.needsAttention else { return "" }
        return " · \(error.message)"
    }
}

// MARK: - Rows

/// A tank with its title, what is left, and a quiet caption stacked beside it.
private struct TankRow: View {
    let slot: TankSlot
    let condition: AccountState.Condition
    let kind: AccountKind

    @AppStorage(Preferences.showPace) private var showPace = true

    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    var body: some View {
        let fill = TankFill(slot, condition: condition)
        HStack(alignment: .top, spacing: 8) {
            TankView(fill: fill, kind: slot.kind, elapsed: showPace ? slot.tank?.elapsedFraction() : nil)
                .animation(.smooth, value: fill)
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.tank?.title ?? title).font(.subheadline)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(condition == .live ? .primary : .secondary)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title for a slot that has no tank in the reading.
    private var title: String {
        switch slot.kind {
        case .session: "Session"
        case .weekly: "Weekly"
        case .pool: "Credit"
        }
    }

    /// Always "left", so the number can't be misread.
    private var value: String {
        guard let tank = slot.tank else { return "—" }
        if let dollars = tank.dollars {
            return "\(dollars.remaining.formatted(Self.dollars)) left"
        }
        return "\(tank.remaining.formatted(.percent.precision(.fractionLength(0)))) left"
    }

    private var caption: String? {
        guard let tank = slot.tank else { return nil }
        let reset = tank.resetsAt.map { ResetText.string(for: $0) }
        guard let dollars = tank.dollars else { return reset }
        let limit = "of \(dollars.limit.formatted(Self.dollars))\(kind == .anthropicAPI ? " budget" : "")"
        return [limit, reset].compactMap(\.self).joined(separator: " · ")
    }
}

private struct ScopedRow: View {
    let limit: ScopedLimit

    var body: some View {
        HStack {
            Text("\(limit.name) only")
            Spacer()
            Text("\((1 - limit.fraction).formatted(.percent.precision(.fractionLength(0)))) left")
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Footer

private struct Footer: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    /// True while a refresh that the user started with the refresh button is running.
    @State private var userIsRefreshing = false

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                // Every refresh shows here, whatever started it.
                if store.isRefreshing {
                    Text("Updating…")
                } else if let updated = store.lastUpdated {
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                userIsRefreshing = true
                Task {
                    await store.refresh()
                    userIsRefreshing = false
                }
            } label: {
                // The icon turns only for a refresh that the user asked for with this button.
                // A refresh on a timer, on wake, or when the panel opens leaves it still.
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: userIsRefreshing)
            }
            .help("Refresh")
            .disabled(store.isRefreshing)

            Button {
                dismiss()
                // A menu bar app isn't frontmost, so bring it forward or the window opens behind.
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .keyboardShortcut(",")

            Menu {
                Button("Quit AI Meter") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }
}
