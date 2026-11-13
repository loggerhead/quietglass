import AppKit
import XCTest
import ShieldCore
@testable import QuietGlass

@MainActor private final class AreaTestExecutor: ProtectionPlanExecuting {
    func apply(_ plan: ProtectionPlan) {}
    func shutdown() {}
}

@MainActor
final class ProtectedAreaTests: XCTestCase {
    func testClearScreenDiscardsAreasInsteadOfOnlyPausingThem() throws {
        let suite = "QuietGlass.AreaTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: AreaTestExecutor(), runsTimer: false)
        coordinator.prepareEscape = { false }; coordinator.prepareRuleBindings = { _ in true }
        let source = RuleEventSources(coordinator: coordinator)
        let controller = PrivacyController(); controller.attachRules(source)
        defer { controller.shutdown(); coordinator.shutdown(); prefs.removePersistentDomain(forName: suite) }
        let window = ProtectedWindowRef(bundleID: "sample.app", windowID: 99, ownerPID: -1)
        source.protect(reference: window, name: "Sample", rectangle: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(controller.protectedAreas.count, 1)
        controller.pauseProtection()
        XCTAssertEqual(controller.protectedAreas.count, 1)
        XCTAssertTrue(controller.paused)
        controller.dismissAll()
        XCTAssertTrue(controller.protectedAreas.isEmpty)
        XCTAssertTrue(controller.paused)
        controller.resume()
        XCTAssertTrue(controller.protectedAreas.isEmpty)
    }

    func testRemoveOneAreaPreservesTheOtherUntilRemoveAll() throws {
        let suite = "QuietGlass.AreaTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: AreaTestExecutor(), runsTimer: false)
        coordinator.prepareEscape = { false }; coordinator.prepareRuleBindings = { _ in true }
        let source = RuleEventSources(coordinator: coordinator)
        let controller = PrivacyController(); controller.attachRules(source)
        defer { controller.shutdown(); coordinator.shutdown(); prefs.removePersistentDomain(forName: suite) }
        let window = ProtectedWindowRef(bundleID: "sample.app", windowID: 99, ownerPID: -1)
        source.protect(reference: window, name: "Sample", rectangle: CGRect(x: 0, y: 0, width: 0.4, height: 0.4))
        source.protect(reference: window, name: "Sample", rectangle: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4))
        let remaining = controller.protectedAreas[1].id
        controller.removeArea(controller.protectedAreas[0].id)
        XCTAssertEqual(controller.protectedAreas.map(\.id), [remaining])
        controller.removeAllAreas()
        XCTAssertTrue(controller.protectedAreas.isEmpty)
    }
}
