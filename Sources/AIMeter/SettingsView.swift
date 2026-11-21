import AIMeterCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: UsageStore
    let updater: AppUpdater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(store: store)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            Tab("Appearance", systemImage: "paintbrush") {
                AppearanceSettingsView(store: store)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsSettingsView(store: store)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            Tab("About", systemImage: "info.circle") {
                AboutView(updater: updater)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        // AppKit only blends the toolbar into the content when a scroll view sits
        // directly beneath it (true for the forms, not Accounts' split layout).
        // Hiding it explicitly keeps the tab bar identical on every tab.
        // One size for every tab, so the window doesn't jump when switching.
        // Every tab is laid out to fit this size without scrolling.
        .frame(width: 660, height: 520)
        .background(SettingsWindowSetup(title: "AI Meter"))
    }
}

/// Reaches the Settings window that SwiftUI creates, to set what SwiftUI has no modifier for.
///
/// SwiftUI titles the window after the selected tab. This keeps it showing the app
/// name instead, re-applying it whenever SwiftUI changes it. It also makes the window
/// follow the user to the current Space.
private struct SettingsWindowSetup: NSViewRepresentable {
    let title: String

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
            // Opening Settings while its window sits on another Space brings the
            // window to the current Space, instead of switching Spaces to reach it.
            window?.collectionBehavior.insert(.moveToActiveSpace)
            observation = window?.observe(\.title, options: [.initial]) { [title] window, _ in
                MainActor.assumeIsolated {
                    if window.title != title { window.title = title }
                }
            }
        }
    }
}

struct GeneralSettingsView: View {
    let store: UsageStore

    @AppStorage(Preferences.refreshMinutes) private var refreshMinutes = Preferences.defaultRefreshMinutes
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Refresh", selection: $refreshMinutes) {
                    ForEach(Preferences.refreshChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
            } footer: {
                SettingsFootnote("AI Meter also refreshes when the Mac wakes and when you open the panel. A reading that misses two refreshes is drawn striped, to show that it is no longer current.")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
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
}

struct AppearanceSettingsView: View {
    let store: UsageStore

    @AppStorage(Preferences.showPace) private var showPace = true
    @AppStorage(Preferences.showLogos) private var showLogos = true

    var body: some View {
        Form {
            Section("Menu Bar") {
                LabeledContent("Preview") {
                    Image(nsImage: MenuBarIcon.image(for: store.visibleStates, staleAfter: store.staleAfter, showLogos: showLogos))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                Toggle(isOn: $showLogos) {
                    Text("Show service logos")
                    Text("A small mark before each service's tanks, in the menu bar and the panel.")
                }
            }

            Section("Panel") {
                Toggle(isOn: $showPace) {
                    Text("Show pace marker")
                    Text("A tick showing where the level would be if usage were spread evenly across the window.")
                }
            }

            Section("Tanks and API Spend") {
                TankLegend()
                SpendLegend()
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Shows each way a tank can be drawn, so the stripes and outlines need no guessing.
private struct TankLegend: View {
    private let entries: [(TankFill, String)] = [
        (.live(remaining: 0.7, level: .normal), "Current"),
        (.live(remaining: 0.2, level: .warning), "Under 25%"),
        (.live(remaining: 0.06, level: .critical), "Under 10%"),
        (.lastKnown(remaining: 0.7), "Out of date"),
        (.unavailable, "Can't read"),
    ]

    var body: some View {
        HStack(alignment: .top) {
            ForEach(entries, id: \.1) { fill, label in
                VStack(spacing: 6) {
                    TankView(fill: fill, kind: .weekly, height: 40)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shows each way a spend chip can be drawn, in the same order as the tanks above it.
private struct SpendLegend: View {
    private let entries: [(SpendFill, String)] = [
        (.live(dollars: 42, level: .normal), "Current"),
        (.live(dollars: 120, level: .warning), "Over orange"),
        (.live(dollars: 1240, level: .critical), "Over red"),
        (.lastKnown(dollars: 42), "Out of date"),
        (.unavailable, "Can't read"),
    ]

    var body: some View {
        HStack(alignment: .top) {
            ForEach(entries, id: \.1) { fill, label in
                VStack(spacing: 6) {
                    SpendChipView(fill: fill, height: 18)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsFootnote: View {
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
