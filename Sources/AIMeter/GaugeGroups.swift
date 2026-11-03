import AIMeterCore
import Foundation

extension UsageStore {
    /// Menu bar groups for the services the user has left visible, in `Service` order.
    @MainActor
    func visibleGaugeGroups(defaults: UserDefaults = .standard) -> [MenuBarIcon.Group] {
        Service.allCases
            .filter { defaults.object(forKey: $0.visibilityKey) as? Bool ?? true }
            .map { MenuBarIcon.Group(service: $0, gauges: gauges(for: $0)) }
    }
}
