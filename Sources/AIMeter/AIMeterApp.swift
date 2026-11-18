import AIMeterCore
import AppKit
import SwiftUI

@main
struct AIMeterApp: App {
    @State private var store: UsageStore
    @State private var updater = AppUpdater()

    @AppStorage(Preferences.showLogos) private var showLogos = true

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
            Image(nsImage: MenuBarIcon.image(for: store.visibleStates, staleAfter: store.staleAfter, showLogos: showLogos))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, updater: updater)
        }
        .windowResizability(.contentSize)
    }
}
