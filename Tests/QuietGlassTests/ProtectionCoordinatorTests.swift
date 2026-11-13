import XCTest
import ShieldCore
@testable import QuietGlass

@MainActor
private final class RecordingProtectionExecutor: ProtectionPlanExecuting {
    var plans: [ProtectionPlan] = []
    var stopped = false
    func apply(_ plan: ProtectionPlan) { plans.append(plan) }
    func shutdown() { stopped = true }
}

final class ProtectionCoordinatorTests: XCTestCase {
    @MainActor func testResumeWakeAndPauseExpirySubmitOnlyFreshWindowGeometry() throws {
        for mode in ["resume", "wake", "uptime", "wall"] {
            let suite = "QuietGlass.ResumeContext.\(UUID())"
            let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { prefs.removePersistentDomain(forName: suite) }
            var now = 1.0, wall = Date(timeIntervalSince1970: 1)
            let executor = RecordingProtectionExecutor()
            let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: executor,
                clock: { now }, wallClock: { wall }, runsTimer: false)
            defer { coordinator.shutdown() }
            coordinator.prepareEscape = { true }
            let ref = ProtectedWindowRef(bundleID: "test.editor", windowID: 1, ownerPID: 2)
            let rule = ProtectionRule(name: "Window", trigger: .manual(shortcut: nil), scope: .window(ref))
            try coordinator.saveRules([rule])
            let display = ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let old = CGRect(x: 10, y: 10, width: 200, height: 200), fresh = CGRect(x: 400, y: 300, width: 250, height: 200)
            coordinator.send([.displays([display]), .permission(.screen, granted: true),
                .windows([ProtectionWindow(reference: ref, frame: old)], activeWindow: old, activeBundleID: ref.bundleID), .manual(rule.id, active: true)])
            if mode == "wake" { coordinator.suspend() } else { coordinator.pause(seconds: mode == "resume" ? nil : 100) }
            var snapshots = 0
            coordinator.refreshContext = {
                snapshots += 1
                return [.displays([display]), .windows([ProtectionWindow(reference: ref, frame: fresh)], activeWindow: fresh, activeBundleID: ref.bundleID)]
            }
            executor.plans = []
            switch mode {
            case "resume": coordinator.resume()
            case "wake": coordinator.wake()
            case "uptime": now = 102; coordinator.send(.tick)
            default: now = 2; wall = Date(timeIntervalSince1970: 102); coordinator.send(.tick)
            }
            XCTAssertEqual(snapshots, 1, mode)
            XCTAssertEqual(executor.plans.count, 1, "\(mode) must not render an intermediate stale plan")
            XCTAssertEqual(executor.plans[0].displays[0].regions.map(\.rectangle), [fresh], mode)
            if mode == "uptime" || mode == "wall" {
                let values = try XCTUnwrap(try PropertyListSerialization.propertyList(from: coordinator.document.preferences.appearance, format: nil) as? [String: Any])
                XCTAssertEqual(values["protectionPaused"] as? Bool, false)
                XCTAssertNil(values["protectionPauseUntil"])
            }
        }
    }
    @MainActor func testExpiredPauseRemainsSuspendedUntilWakeAndThenUsesFreshContext() throws {
        let suite = "QuietGlass.SleepExpiry.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { prefs.removePersistentDomain(forName: suite) }
        var now = 1.0, wall = Date(timeIntervalSince1970: 1)
        let executor = RecordingProtectionExecutor()
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: executor,
            clock: { now }, wallClock: { wall }, runsTimer: false)
        defer { coordinator.shutdown() }
        coordinator.prepareEscape = { true }
        let rule = ProtectionRule(name: "Manual", trigger: .manual(shortcut: nil), scope: .allDisplays)
        try coordinator.saveRules([rule])
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]),
                          .permission(.screen, granted: true), .manual(rule.id, active: true)])
        coordinator.pause(seconds: 100); coordinator.suspend()
        var snapshots = 0; coordinator.refreshContext = { snapshots += 1; return [] }
        now = 102; wall = Date(timeIntervalSince1970: 102)
        coordinator.send(.tick)
        XCTAssertEqual(coordinator.plan.state, .suspended); XCTAssertFalse(coordinator.plan.hasProtection)
        XCTAssertEqual(snapshots, 0, "Sleeping ticks must not wake geometry or protection sources")
        coordinator.wake()
        XCTAssertEqual(snapshots, 1); XCTAssertEqual(coordinator.plan.state, .running); XCTAssertTrue(coordinator.plan.hasProtection)
    }
    @MainActor func testResumePauseAndClearCommandsKeepLifecycleSuspension() throws {
        let suite = "QuietGlass.SuspendedCommands.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { prefs.removePersistentDomain(forName: suite) }
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: RecordingProtectionExecutor(), runsTimer: false)
        defer { coordinator.shutdown() }
        coordinator.suspend(); coordinator.resume()
        XCTAssertEqual(coordinator.plan.state, .suspended)
        coordinator.pause(); XCTAssertEqual(coordinator.plan.state, .suspended)
        coordinator.wake(); XCTAssertEqual(coordinator.plan.state, .paused(until: nil))
        coordinator.suspend(); coordinator.clear()
        XCTAssertEqual(coordinator.plan.state, .suspended)
        coordinator.wake(); XCTAssertEqual(coordinator.plan.state, .cleared)
    }
    @MainActor func testEscapeWinsOverOrdinaryActivationsWithinOneBatch() throws {
        let suite = "QuietGlass.EscapeBatch.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { prefs.removePersistentDomain(forName: suite) }
        let executor = RecordingProtectionExecutor()
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: executor, runsTimer: false)
        defer { coordinator.shutdown() }
        coordinator.prepareEscape = { true }
        let rule = ProtectionRule(name: "Manual", trigger: .manual(shortcut: nil), scope: .allDisplays)
        try coordinator.saveRules([rule]); executor.plans = []
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]),
            .permission(.screen, granted: true), .manual(rule.id, active: true), .escape, .manual(rule.id, active: true)])
        XCTAssertEqual(executor.plans.count, 1); XCTAssertFalse(coordinator.plan.hasProtection)
        XCTAssertEqual(coordinator.plan.state, .cleared); XCTAssertFalse(coordinator.isManuallyActivated(rule.id))
    }
    @MainActor func testEscapeIsBorrowedAfterManualActivationAndReleasedWhenCleared() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: RecordingProtectionExecutor(), runsTimer: false)
        var needs: [Bool] = []
        coordinator.prepareEscape = { [weak coordinator] in
            let value = coordinator?.requiresEscape == true; needs.append(value); return value
        }
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]), .permission(.screen, granted: true)])
        XCTAssertEqual(needs.last, false)
        let manual = try XCTUnwrap(coordinator.document.rules.first { if case .manual = $0.trigger { return $0.scope == .allDisplays }; return false })
        coordinator.toggleManual(manual.id)
        XCTAssertEqual(needs.last, true)
        XCTAssertTrue(coordinator.plan.hasProtection)
        coordinator.clear()
        XCTAssertEqual(needs.last, false)
        XCTAssertFalse(coordinator.plan.hasProtection)
        coordinator.shutdown()
    }
    @MainActor func testEmptyBatchReevaluatesEscapeBeforeSubmittingAnyCoverage() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: RecordingProtectionExecutor(), runsTimer: false)
        coordinator.prepareEscape = { true }
        let rule = try XCTUnwrap(coordinator.document.rules.first { if case .manual = $0.trigger { return $0.scope == .allDisplays }; return false })
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]), .permission(.screen, granted: true), .manual(rule.id, active: true)])
        XCTAssertTrue(coordinator.plan.hasProtection)
        coordinator.prepareEscape = { false }
        XCTAssertFalse(coordinator.send([]).hasProtection)
        coordinator.shutdown()
    }
    @MainActor func testPauseRestoresFromMigrationAndWallClockAndExplicitResumeSurviveRelaunch() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        var now = 1.0, wall = Date(timeIntervalSince1970: 1)
        prefs.set(true, forKey: "nearbyEnabled"); prefs.set(Date(timeIntervalSince1970: 121), forKey: "nearbyPauseUntil")
        let store = ProtectionStore(storage: prefs)
        let coordinator = try ProtectionCoordinator(store: store, executor: RecordingProtectionExecutor(), clock: { now }, wallClock: { wall }, runsTimer: false)
        XCTAssertEqual(coordinator.plan.state, .paused(until: 121))
        now = 2; wall = Date(timeIntervalSince1970: 122)
        XCTAssertEqual(coordinator.send(.tick).state, .running, "Wall time must include time spent asleep")
        coordinator.pause()
        let restored = try ProtectionCoordinator(store: store, executor: RecordingProtectionExecutor(), clock: { now }, wallClock: { wall }, runsTimer: false)
        XCTAssertEqual(restored.plan.state, .paused(until: nil))
        restored.resume()
        let resumed = try ProtectionCoordinator(store: store, executor: RecordingProtectionExecutor(), clock: { now }, wallClock: { wall }, runsTimer: false)
        XCTAssertEqual(resumed.plan.state, .running)
        XCTAssertEqual(prefs.object(forKey: "nearbyPauseUntil") as? Date, Date(timeIntervalSince1970: 121), "The original legacy key is read-only")
        coordinator.shutdown(); restored.shutdown(); resumed.shutdown()
    }
    @MainActor func testUnavailableSystemBindingRejectsEditBeforePersistence() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: RecordingProtectionExecutor(), runsTimer: false)
        let original = coordinator.document
        let data = prefs.data(forKey: ProtectionStore.documentKey)
        coordinator.prepareRuleBindings = { _ in false }
        var edited = original; edited.rules[0].name = "Edited"
        XCTAssertThrowsError(try coordinator.save(edited))
        XCTAssertEqual(coordinator.document, original)
        XCTAssertEqual(prefs.data(forKey: ProtectionStore.documentKey), data)
        coordinator.shutdown()
    }
    @MainActor func testOnePlanPerEventBatchAndGlobalLifecycleCommandsReachExecutor() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let executor = RecordingProtectionExecutor()
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: executor, clock: { 1 }, runsTimer: false)
        let rule = try XCTUnwrap(coordinator.document.rules.first { rule in
            guard rule.scope == .allDisplays else { return false }
            if case .manual = rule.trigger { return true }; return false
        })
        coordinator.send([.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]),
                          .permission(.screen, granted: true), .escapeAvailability(true), .manual(rule.id, active: true)])
        XCTAssertEqual(executor.plans.count, 1); XCTAssertTrue(executor.plans[0].hasProtection)
        coordinator.pause(); XCTAssertFalse(executor.plans.last!.hasProtection)
        coordinator.resume(); XCTAssertTrue(executor.plans.last!.hasProtection)
        coordinator.suspend(); XCTAssertFalse(executor.plans.last!.hasProtection)
        coordinator.wake(); XCTAssertTrue(executor.plans.last!.hasProtection)
        coordinator.clear(); XCTAssertFalse(executor.plans.last!.hasProtection)
        coordinator.shutdown(); XCTAssertTrue(executor.stopped)
    }

    @MainActor func testPresetRepeatedClicksAreIdempotentAndPreserveEditsAcrossRelaunch() throws {
        let suite = "QuietGlass.PresetIdempotency.\(UUID())"; let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = ProtectionStore(storage: prefs)
        let coordinator = try ProtectionCoordinator(store: store, executor: RecordingProtectionExecutor(), runsTimer: false)
        defer { coordinator.shutdown() }
        let id = try coordinator.addPreset(.nearby)
        let after = coordinator.document
        XCTAssertEqual(try coordinator.addPreset(.nearby), id); XCTAssertEqual(coordinator.document, after)
        var rules = after.rules; let index = try XCTUnwrap(rules.firstIndex { $0.id == id }); rules[index].name = "My nearby setup"; rules[index].action = .warnOnly(delay: 12.5, sound: false)
        try coordinator.saveRules(rules)
        let restored = try ProtectionCoordinator(store: store, executor: RecordingProtectionExecutor(), runsTimer: false)
        defer { restored.shutdown() }
        XCTAssertEqual(try restored.addPreset(.nearby), id)
        XCTAssertEqual(restored.document.rules.first { $0.id == id }?.name, "My nearby setup")
        XCTAssertEqual(restored.document.rules.first { $0.id == id }?.action, .warnOnly(delay: 12.5, sound: false))
        XCTAssertEqual(restored.document.rules.count, after.rules.count)
    }

    @MainActor func testInvalidEditorSaveCannotChangeLiveRulesOrPersistentData() throws {
        let suite = "QuietGlass.RuleCoordinatorTests.\(UUID())"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: prefs), executor: RecordingProtectionExecutor(), runsTimer: false)
        let before = coordinator.document
        let data = prefs.data(forKey: ProtectionStore.documentKey)
        var rules = before.rules; rules[0].scope = .detectedText
        XCTAssertThrowsError(try coordinator.saveRules(rules))
        XCTAssertEqual(coordinator.document, before)
        XCTAssertEqual(prefs.data(forKey: ProtectionStore.documentKey), data)
        try coordinator.addPreset(.nearby)
        XCTAssertEqual(coordinator.document.rules.count, before.rules.count + 1)
        coordinator.shutdown()
    }

    @MainActor func testWarningSoundPlaysOncePerRuleAndNotWhenMuted() {
        var played = 0
        let presenter = WarningPresenter(makeSound: { NearbyNoticeSound(play: { played += 1 }) })
        let status = ActiveProtectionRule(id: UUID(), name: "Nearby", reason: .extraFace)
        presenter.present([ProtectionWarning(rule: status, secondsRemaining: 120, sound: true)])
        presenter.present([ProtectionWarning(rule: status, secondsRemaining: 119, sound: true)])
        XCTAssertEqual(played, 1)
        presenter.present([])
        presenter.present([ProtectionWarning(rule: status, secondsRemaining: 120, sound: false)])
        presenter.present([ProtectionWarning(rule: status, secondsRemaining: 119, sound: true)])
        XCTAssertEqual(played, 1)
    }
}
