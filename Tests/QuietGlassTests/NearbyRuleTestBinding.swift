import Foundation
import ShieldCore
@testable import QuietGlass

@MainActor private final class NearbyTestExecutor: ProtectionPlanExecuting {
    var onApply: ((ProtectionPlan) -> Void)?
    func apply(_ plan: ProtectionPlan) { onApply?(plan) }
    func shutdown() {}
}

/// Tests use the production camera-to-rule adapter and persistence path; only
/// capture output and the clock are injected. Legacy configuration is read-only.
@MainActor final class NearbyRuleTestBinding {
    let coordinator: ProtectionCoordinator
    let adapter: NearbyRuleAdapter
    private let executor = NearbyTestExecutor()
    var onPlan: ((ProtectionPlan) -> Void)? { get { executor.onApply } set { executor.onApply = newValue } }
    var primary: ProtectionRule { coordinator.document.rules.first { if case .extraFace = $0.trigger { return true }; return false }! }
    init(nearby: NearbyPeople, preferences: UserDefaults, clock: @escaping () -> TimeInterval,
         wallClock: @escaping () -> Date = Date.init, runsTimer: Bool = false) throws {
        coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: preferences), executor: executor,
                                               clock: clock, wallClock: wallClock, runsTimer: runsTimer)
        coordinator.warnings.visible = false
        coordinator.prepareEscape = { true }; coordinator.prepareRuleBindings = { _ in true }
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))]),
                          .permission(.screen, granted: true), .permission(.camera, granted: true)])
        adapter = NearbyRuleAdapter(nearby: nearby, coordinator: coordinator, cameraPermission: { true })
        coordinator.onRulesChanged = { [weak adapter] in adapter?.configure($0) }
        coordinator.onPlanChanged = { [weak adapter] in adapter?.present($0) }
        adapter.present(coordinator.plan); adapter.configure(coordinator.document, startIfNeeded: false)
    }
    func shutdown() { coordinator.shutdown() }
}
