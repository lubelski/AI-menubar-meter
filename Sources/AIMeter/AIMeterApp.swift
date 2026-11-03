import AIMeterCore
import AppKit
import SwiftUI

@main
struct AIMeterApp: App {
    @State private var store: UsageStore

    @AppStorage(Preferences.meterStyle) private var style = MeterStyle.used
    @AppStorage(Service.claude.visibilityKey) private var showClaude = true
    @AppStorage(Service.openAI.visibilityKey) private var showOpenAI = true
    @AppStorage(Service.apiCredit.visibilityKey) private var showAPICredit = true

    init() {
        let store = UsageStore(interval: Preferences.refreshInterval)
        store.start()
        _store = State(initialValue: store)

        // Numbers go stale across sleep; refresh as soon as the Mac wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await store.refresh() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: gaugeGroups, style: style))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }

    private var gaugeGroups: [[UsageGauge]] {
        [(Service.claude, showClaude), (.openAI, showOpenAI), (.apiCredit, showAPICredit)]
            .filter(\.1)
            .map { store.gauges(for: $0.0) }
    }
}
