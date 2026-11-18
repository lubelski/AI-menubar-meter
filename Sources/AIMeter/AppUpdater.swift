import Foundation
import Sparkle

/// Keeps the app up to date with Sparkle.
///
/// Only a release build updates itself. `scripts/release.sh` writes the feed address and
/// the public signing key into Info.plist; a build without them, such as one from
/// `scripts/bundle.sh` alone, has no updater, so a development copy is never replaced.
@MainActor
@Observable
final class AppUpdater {
    /// Whether this build can update itself.
    let isAvailable: Bool
    /// False while a check is already running.
    private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController?
    private let delegate = Delegate()
    private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary
        guard info?["SUFeedURL"] is String, info?["SUPublicEDKey"] is String else {
            isAvailable = false
            controller = nil
            return
        }
        isAvailable = true
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
        )
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial]) { [weak self] updater, _ in
            // Sparkle changes this property on the main thread.
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// Whether Sparkle looks for, downloads and installs updates without asking.
    var updatesAutomatically: Bool {
        get {
            access(keyPath: \.updatesAutomatically)
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.updatesAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// Checks now and shows Sparkle's own windows with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        /// Sparkle normally installs a downloaded update when the app quits. A menu bar
        /// app stays open for weeks, so install and relaunch as soon as the update is ready.
        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            immediateInstallHandler()
            return true
        }
    }
}
