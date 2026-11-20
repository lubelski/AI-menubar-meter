import AIMeterCore
import SwiftUI

struct UsagePanel: View {
    let store: UsageStore
    let updater: AppUpdater

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
            Footer(store: store, updater: updater)
        }
        .padding(16)
        .frame(width: width)
        // Keep the content at its ideal height, whatever height the window proposes.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { store.refreshIfStale() }
    }

    /// Wider when an account shows three rate-limit tanks in its row, so their captions have room.
    private var width: CGFloat {
        let widest = store.visibleStates.map { $0.slots.filter { $0.kind != .pool }.count }.max() ?? 0
        return widest >= 3 ? 340 : 290
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
                : "Add a Claude, OpenAI, or API spend account in Settings.")
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
    @Environment(\.openURL) private var openURL

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

            if let spend = state.spend {
                SpendRow(spend: spend, account: account, fill: SpendFill(state, condition: condition), condition: condition)
            }
            if state.reading != nil, !state.slots.isEmpty {
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
            Menu {
                Button("View Usage on the Web") { openURL(account.kind.usagePage) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // A borderless menu's label ignores the foreground style but follows the tint.
            // Secondary, like the panel's other small icons.
            .tint(.secondary)
            .help("More for \(account.name)")
        }
    }

    /// The rate-limit windows share one row, in the same order as the menu bar icon.
    /// A dollar pool, such as a plan's API credit, gets a row of its own below them.
    private func tanks(_ condition: AccountState.Condition) -> some View {
        let slots = state.slots
        let rows = [slots.filter { $0.kind != .pool }, slots.filter { $0.kind == .pool }]
            .filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.first?.kind) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { slot in
                        TankRow(slot: slot, condition: condition)
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
        case .fable: "Fable"
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
        let limit = "of \(dollars.limit.formatted(Self.dollars))"
        return [limit, reset].compactMap(\.self).joined(separator: " · ")
    }
}

/// A spend chip with the exact amount, when it starts over, and the month's total beside it.
private struct SpendRow: View {
    let spend: Spend
    let account: Account
    let fill: SpendFill
    let condition: AccountState.Condition

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SpendChipView(fill: fill)
            VStack(alignment: .leading, spacing: 3) {
                // Anthropic's cost report comes in whole UTC days, so the title says which day this is.
                Text(spend.isUTCDay ? "Today (UTC)" : "Today").font(.subheadline)
                Text(spend.today.formatted(.currency(code: "USD")))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(condition == .live ? .primary : .secondary)
                Group {
                    Text(ResetText.string(for: spend.resetsAt))
                    Text("\(spend.monthToDate.formatted(.currency(code: "USD"))) this month")
                    if let discount = account.discountPercent, discount > 0 {
                        Text("After your \(discount.formatted(.number.precision(.fractionLength(0...2))))% discount")
                    }
                    if !spend.unpricedModels.isEmpty {
                        Text("Not counted, no known price: \(spend.unpricedModels.joined(separator: ", "))")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let updater: AppUpdater
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

            Menu {
                // The order of a standard app menu. Only a release build can update itself.
                if updater.isAvailable {
                    Button("Check for Updates…") {
                        // Sparkle shows its own window, so close the panel and come forward.
                        dismiss()
                        NSApp.activate()
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheck)
                }
                Button("Settings…") {
                    dismiss()
                    // A menu bar app isn't frontmost, so bring it forward or the window opens behind.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Divider()
                Button("Quit AI Meter") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.borderless)
    }
}
