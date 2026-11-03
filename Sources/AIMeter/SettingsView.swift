import AIMeterCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: UsageStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(store: store)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsSettingsView(store: store)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        // AppKit only blends the toolbar into the content when a scroll view sits
        // directly beneath it (true for General's form, not Accounts' split layout).
        // Hiding it explicitly keeps the tab bar identical on every tab.
        // One size for every tab, so the window doesn't jump when switching.
        .frame(width: 660, height: 520)
        .background(FixedWindowTitle("AI Meter"))
    }
}

/// SwiftUI titles the Settings window after the selected tab. This keeps it
/// showing the app name instead, re-applying it whenever SwiftUI changes it.
private struct FixedWindowTitle: NSViewRepresentable {
    let title: String

    init(_ title: String) { self.title = title }

    func makeNSView(context: Context) -> TitleKeeper { TitleKeeper(title: title) }
    func updateNSView(_ view: TitleKeeper, context: Context) {}

    final class TitleKeeper: NSView {
        private let title: String
        private var observation: NSKeyValueObservation?

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.title, options: [.initial]) { [title] window, _ in
                MainActor.assumeIsolated {
                    if window.title != title { window.title = title }
                }
            }
        }
    }
}

private struct GeneralSettingsView: View {
    let store: UsageStore

    @AppStorage(Preferences.meterStyle) private var style = Preferences.defaultMeterStyle
    @AppStorage(Preferences.showPace) private var showPace = true
    @AppStorage(Preferences.showLogos) private var showLogos = true
    @AppStorage(Preferences.refreshMinutes) private var refreshMinutes = Preferences.defaultRefreshMinutes
    @AppStorage(Service.claude.visibilityKey) private var showClaude = true
    @AppStorage(Service.openAI.visibilityKey) private var showOpenAI = true
    @AppStorage(Service.apiCredit.visibilityKey) private var showAPICredit = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Meters", selection: $style) {
                    MeterStyleOption(title: "Drain as you use them", example: 0.3).tag(MeterStyle.remaining)
                    MeterStyleOption(title: "Fill up as you use them", example: 0.7).tag(MeterStyle.used)
                }
                .pickerStyle(.radioGroup)

                LabeledContent("Menu bar") {
                    Image(nsImage: MenuBarIcon.image(for: visibleGaugeGroups, style: style, showLogos: showLogos))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }

                Toggle(isOn: $showLogos) {
                    Text("Show service logos")
                    Text("A small mark before each group of meters, in the menu bar and the panel.")
                }

                Toggle(isOn: $showPace) {
                    Text("Show pace marker")
                    Text("A tick showing where you'd be if usage were spread evenly across the window.")
                }
            }

            Section("Show") {
                Toggle(Service.claude.title, isOn: $showClaude)
                    .disabled(isLastVisible(showClaude))
                Toggle(Service.apiCredit.title, isOn: $showAPICredit)
                    .disabled(isLastVisible(showAPICredit))
                Toggle(Service.openAI.title, isOn: $showOpenAI)
                    .disabled(isLastVisible(showOpenAI))
            }

            Section("General") {
                Picker("Refresh", selection: $refreshMinutes) {
                    ForEach(Preferences.refreshChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onChange(of: refreshMinutes) { _, minutes in
            store.setInterval(.seconds(60 * minutes))
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var visibleGaugeGroups: [MenuBarIcon.Group] {
        _ = (showClaude, showOpenAI, showAPICredit)
        return store.visibleGaugeGroups()
    }

    /// Keeps at least one service on, so the menu bar item never disappears.
    private func isLastVisible(_ isOn: Bool) -> Bool {
        isOn && [showClaude, showOpenAI, showAPICredit].filter(\.self).count == 1
    }
}

/// A radio option with a tiny sample bar, so the choice is visual rather than verbal.
private struct MeterStyleOption: View {
    let title: String
    let example: Double

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 5, height: 14)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Color.accentColor).frame(height: 14 * example)
                }
            Text(title)
        }
    }
}
