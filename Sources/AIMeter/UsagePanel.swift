import AIMeterCore
import SwiftUI

struct UsagePanel: View {
    let store: UsageStore

    @AppStorage(Service.claude.visibilityKey) private var showClaude = true
    @AppStorage(Service.openAI.visibilityKey) private var showOpenAI = true
    @AppStorage(Service.apiCredit.visibilityKey) private var showAPICredit = true
    @AppStorage(AuthPreferences.creditSource) private var creditSource = CreditSource.claudePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showClaude {
                ProviderSection(title: "Claude", plan: store.claude.value?.plan, error: store.claude.error, brand: .anthropic, link: UsagePage.claude) {
                    if let usage = store.claude.value {
                        HStack(alignment: .top, spacing: 12) {
                            WindowRow(title: "Session", kind: .session, window: usage.session)
                            WindowRow(title: "Weekly", kind: .weekly, window: usage.weekly)
                        }
                        ForEach(usage.scopedWeekly, id: \.name) { limit in
                            ScopedRow(limit: limit)
                        }
                    }
                }
                Divider()
            }

            if showAPICredit {
                ProviderSection(title: "API Credit", plan: nil, error: store.credit.error, brand: .anthropic, link: UsagePage.credit(creditSource)) {
                    if let credit = store.credit.value {
                        CreditRow(credit: credit)
                    } else if store.credit.isConnected {
                        Text("No API credit on this plan")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }

            if showOpenAI {
                ProviderSection(title: "OpenAI", plan: store.codex.value?.plan, error: store.codex.error, brand: .openAI, link: UsagePage.codex) {
                    if let usage = store.codex.value {
                        HStack(alignment: .top, spacing: 12) {
                            WindowRow(title: "Session", kind: .session, window: usage.session)
                            WindowRow(title: "Weekly", kind: .weekly, window: usage.weekly)
                        }
                    }
                }
                Divider()
            }

            Footer(store: store)
        }
        .padding(16)
        .frame(width: 290)
        // Pin the height to the content. Otherwise the MenuBarExtra window can keep a
        // stale, taller size and show empty glass above and below the panel.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { store.refreshIfStale() }
    }
}

// MARK: - Sections

/// Web pages that show the same numbers in full, linked from each section header.
private enum UsagePage {
    static let claude = URL(string: "https://claude.ai/settings/usage")!
    static let codex = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let platformCost = URL(string: "https://platform.claude.com/cost")!

    /// The plan's credit appears on Claude's usage page. Admin API spend is on the platform's cost page.
    static func credit(_ source: CreditSource) -> URL {
        source == .adminKey ? platformCost : claude
    }
}

private struct ProviderSection<Content: View>: View {
    let title: String
    let plan: String?
    let error: ProviderError?
    let brand: Brand
    let link: URL
    @ViewBuilder let content: Content

    @AppStorage(Preferences.showLogos) private var showLogos = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if showLogos {
                    Image(nsImage: BrandMark.image(brand, size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(title).font(.headline)
                if let plan {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: link) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(link.host() ?? "usage page")")
                if let error {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(error.message)
                }
            }
            if let error, error.needsAttention {
                Text("\(error.message). Check Settings → Accounts.")
                    .foregroundStyle(.secondary)
            }
            content
        }
        .font(.caption)
    }
}

// MARK: - Rows

private struct WindowRow: View {
    let title: String
    let kind: UsageGauge.Kind
    let window: UsageWindow?

    @AppStorage(Preferences.meterStyle) private var style = Preferences.defaultMeterStyle

    var body: some View {
        MeterRow(
            title: title,
            kind: kind,
            value: window.map { Text(percentLabel($0.fraction, style: style)) },
            used: window?.fraction,
            elapsed: window?.elapsedFraction(),
            caption: window?.resetsAt.map { ResetText.string(for: $0) }
        )
    }
}

private struct CreditRow: View {
    let credit: CreditUsage

    @AppStorage(Preferences.meterStyle) private var style = Preferences.defaultMeterStyle
    @AppStorage(AuthPreferences.creditSource) private var source = CreditSource.claudePlan

    var body: some View {
        let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))
        let value = switch style {
        case .used: "\(credit.used.formatted(dollars)) used"
        case .remaining: "\(credit.remaining.formatted(dollars)) left"
        }
        MeterRow(
            title: source == .adminKey ? "This month" : "This period",
            kind: .pool,
            value: Text(value),
            used: credit.fraction,
            elapsed: nil,
            caption: ["of \(credit.limit.formatted(dollars))\(source == .adminKey ? " budget" : "")", credit.resetsAt.map { ResetText.string(for: $0) }]
                .compactMap(\.self)
                .joined(separator: " · ")
        )
    }
}

private struct ScopedRow: View {
    let limit: ScopedLimit

    @AppStorage(Preferences.meterStyle) private var style = Preferences.defaultMeterStyle

    var body: some View {
        HStack {
            Text("\(limit.name) only")
            Spacer()
            Text(percentLabel(limit.fraction, style: style))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

/// "55% used" or "45% left" — always explicit, so the number can't be misread.
private func percentLabel(_ used: Double, style: MeterStyle) -> String {
    let percent = style.displayed(used).formatted(.percent.precision(.fractionLength(0)))
    return style == .used ? "\(percent) used" : "\(percent) left"
}

/// A vertical bar with the title, value, and a quiet caption stacked beside it.
private struct MeterRow: View {
    let title: String
    let kind: UsageGauge.Kind
    let value: Text?
    let used: Double?
    let elapsed: Double?
    let caption: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UsageBar(kind: kind, used: used ?? 0, elapsed: elapsed)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline)
                (value ?? Text("—"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
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
}

/// Vertical bar that fills from the bottom, with an optional tick marking where the
/// fill would be if usage were spread evenly across the window.
///
/// Matches the menu bar icon: widths keep its session < weekly < pool proportions,
/// and the fill is monochrome until it turns orange or red.
struct UsageBar: View {
    let kind: UsageGauge.Kind
    let used: Double
    let elapsed: Double?

    @AppStorage(Preferences.meterStyle) private var style = Preferences.defaultMeterStyle
    @AppStorage(Preferences.showPace) private var showPace = true

    private var tint: Color {
        switch UsageLevel(fraction: used) {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Twice the menu bar widths (3, 4.5, 7 pt).
    private var width: CGFloat {
        switch kind {
        case .session: 6
        case .weekly: 9
        case .pool: 14
        }
    }

    /// Thin bars are full pills. The wide pool bar gets softer corners, like a tank.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(width / 2, 5), style: .continuous)
    }

    var body: some View {
        let fraction = style.displayed(used)
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                shape.fill(.primary.opacity(0.18))
                shape
                    .fill(tint)
                    .frame(height: fraction > 0 ? max(proxy.size.height * fraction, 8) : 0)
                if showPace, let elapsed {
                    let pace = style.displayed(elapsed)
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(.primary.opacity(0.55))
                        .frame(width: proxy.size.width + 4, height: 1.5)
                        .offset(y: -(proxy.size.height * pace - 0.75))
                        .help("Even pace: \(Int((elapsed * 100).rounded()))% of the window has elapsed")
                }
            }
        }
        .frame(width: width, height: 64)
        .animation(.smooth, value: fraction)
    }
}

// MARK: - Footer

private struct Footer: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let updated = store.lastUpdated {
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                } else {
                    Text(store.isRefreshing ? "Loading…" : "Not updated yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
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
