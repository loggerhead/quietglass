import AppKit
import XCTest
import ShieldCore
@testable import QuietGlass

@MainActor private final class RuleApplicationExecutor: ProtectionPlanExecuting {
    var plans: [ProtectionPlan] = []
    func apply(_ plan: ProtectionPlan) { plans.append(plan) }
    func shutdown() {}
}
private final class RuleApplicationCamera: NearbyCameraSession {
    let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    var stopped = false
    init(_ completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) { self.completion = completion }
    func start() {}
    func stop() { stopped = true }
}
@MainActor private final class RuleApplicationHarness {
    let suite = "QuietGlass.RuleApplicationTests.\(UUID())"
    let preferences: UserDefaults
    let executor = RuleApplicationExecutor()
    var now: TimeInterval = 1
    var cameras: [RuleApplicationCamera] = []
    var nearby: NearbyPeople!
    var model: AppModel!
    var coordinator: ProtectionCoordinator { model.protectionCoordinator! }
    init(camera: CameraHeadTracking? = nil) throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(17.0, forKey: "comfort"); preferences.set(23.0, forKey: "transition"); preferences.set(52.0, forKey: "blur")
        preferences.set(false, forKey: "nearbyEnabled"); preferences.set("warning", forKey: "nearbyResponse")
        preferences.set(false, forKey: "privacyScanEnabled"); preferences.set(false, forKey: "includeBlurInCaptures")
        nearby = NearbyPeople(cameraAccess: { true }, makeCamera: { [unowned self] completion in
            let camera = RuleApplicationCamera(completion); cameras.append(camera); return camera
        }, clock: { [unowned self] in now }, usesWatchdog: false)
        model = AppModel(preferences: preferences, executor: executor, nearby: nearby, cameraTracking: camera, screenAccess: { true },
                         cameraPermission: { true }, clock: { [unowned self] in now }, runsRuleTimer: false, startsEventSources: false)
        coordinator.prepareEscape = { true }
        coordinator.send(.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))]))
    }
    func settle() async { for _ in 0..<15 { await Task.yield() } }
    func face(_ count: Int, at time: TimeInterval) async {
        now = time
        cameras.last!.completion(.success(NearbyFaceSample(count: count, capturedAt: time)))
        await settle()
    }
    func finish() { model.shutdown(); preferences.removePersistentDomain(forName: suite) }
}

final class RuleApplicationIntegrationTests: OptInDesktopTestCase {
    @MainActor func testAutomaticDetectionChangesOnlyCurrentAutomaticRulesAndRestoresThoseIDs() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        let current = ProtectionRule(name: "Active app", trigger: .appEvent(bundleID: "active.app", event: .activated), scope: .window(ProtectedWindowRef(bundleID: "active.app")))
        let unrelated = ProtectionRule(name: "Other app", trigger: .appEvent(bundleID: "other.app", event: .activated), scope: .window(ProtectedWindowRef(bundleID: "other.app")))
        let manual = ProtectionRule(name: "Manual", trigger: .manual(shortcut: nil), scope: .allDisplays)
        try h.coordinator.saveRules([current, unrelated, manual])
        h.coordinator.send([.windows([ProtectionWindow(reference: ProtectedWindowRef(bundleID: "active.app", windowID: 1), frame: CGRect(x: 10, y: 10, width: 200, height: 200))], activeWindow: nil, activeBundleID: "active.app"), .manual(manual.id, active: true)])
        XCTAssertEqual(h.model.currentAutomaticRuleIDs, [current.id])
        XCTAssertTrue(h.model.automaticDetectionEnabled)
        h.model.setAutomaticDetection(false)
        XCTAssertFalse(h.coordinator.document.rules.first { $0.id == current.id }!.isEnabled)
        XCTAssertTrue(h.coordinator.document.rules.first { $0.id == unrelated.id }!.isEnabled)
        XCTAssertTrue(h.coordinator.isManuallyActivated(manual.id))
        h.model.setAutomaticDetection(true)
        XCTAssertTrue(h.coordinator.document.rules.first { $0.id == current.id }!.isEnabled)
        XCTAssertTrue(h.coordinator.document.rules.first { $0.id == unrelated.id }!.isEnabled)
        XCTAssertEqual(h.coordinator.document.rules.map(\.id), [current.id, unrelated.id, manual.id])
    }

    @MainActor func testEnablingMissingAccessGuidesScreenAndCameraWithoutClaimingCoverage() throws {
        let suite = "QuietGlass.PermissionGuide.\(UUID())"; let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let nearby = NearbyPeople(cameraAccess: { false }, usesWatchdog: false)
        let model = AppModel(preferences: prefs, executor: RuleApplicationExecutor(), nearby: nearby,
            screenAccess: { false }, cameraPermission: { false }, runsRuleTimer: false, startsEventSources: false)
        defer { model.shutdown() }
        var requested: [PermissionKind] = []; model.requestRulePermission = { requested.append($0) }
        let coordinator = try XCTUnwrap(model.protectionCoordinator); coordinator.prepareEscape = { true }; coordinator.prepareRuleBindings = { _ in true }
        var rule = ProtectionPreset.nearby.rule(); rule.isEnabled = false
        try coordinator.saveRules([rule]); XCTAssertTrue(requested.isEmpty)
        try coordinator.setEnabled(rule.id, true)
        XCTAssertEqual(Set(requested), [.screen, .camera])
        XCTAssertEqual(model.missingPermissions(for: rule), [.screen, .camera])
        XCTAssertFalse(coordinator.plan.hasProtection)
        try coordinator.setEnabled(rule.id, false); try coordinator.setEnabled(rule.id, true)
        XCTAssertEqual(requested.count, 4, "Each explicit re-enable should guide access once")
    }

    @MainActor func testSelectionUsesTheActivatedRecipeAndPreservesOtherWindowRules() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        let source = try XCTUnwrap(h.model.privacy.ruleSources)
        let first = ProtectionRule(name: "First", trigger: .manual(shortcut: nil), scope: .window(ProtectedWindowRef(bundleID: "$selection")), action: .blur(BlurParameters(radius: 10), peek: nil))
        let second = ProtectionRule(name: "Second", priority: 75, trigger: .manual(shortcut: nil), scope: .window(ProtectedWindowRef(bundleID: "$selection")), action: .blur(BlurParameters(radius: 55), peek: nil), guards: [.notPaused])
        let existing = ProtectionRule(name: "Existing", trigger: .manual(shortcut: nil), scope: .window(ProtectedWindowRef(bundleID: "test.app", windowID: 2, ownerPID: 4)))
        try h.coordinator.saveRules([first, second, existing])
        source.protect(reference: ProtectedWindowRef(bundleID: "test.app", windowID: 3, ownerPID: 4), name: "Selected", recipeID: second.id)
        let created = try XCTUnwrap(h.coordinator.document.rules.first { $0.name == "Selected" })
        XCTAssertEqual(created.action, second.action); XCTAssertEqual(created.guards, second.guards); XCTAssertEqual(created.priority, second.priority)
        XCTAssertTrue(h.coordinator.document.rules.contains { $0.id == existing.id })
    }
    @MainActor func testAppearanceDefaultsDoNotOverwriteCustomAppConditionBlur() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        let custom = ProtectionRule(name: "Custom", isEnabled: false, priority: 100, trigger: .headTurn(source: .airPods), scope: .allDisplays,
            action: .blur(BlurParameters(radius: 66, comfort: 6, transition: 6), peek: nil), guards: [.appCondition(bundleID: "custom.app")])
        try h.coordinator.saveRules([custom]); h.model.blur = 30
        XCTAssertEqual(h.coordinator.document.rules.first?.action, custom.action)
    }
    @MainActor func testCameraRuleRunsAlongsideUncalibratedAirPodsAndResumeRejectsOldSamples() async throws {
        var clock = 1.0
        var cameras: [RuleApplicationCamera] = []
        let tracker = CameraHeadTracking(access: { true }, makeCamera: { completion in
            let camera = RuleApplicationCamera(completion); cameras.append(camera); return camera
        }, clock: { clock }, usesTimer: false)
        let h = try RuleApplicationHarness(camera: tracker); defer { h.finish() }
        h.model.onRequestHeadSetup = {} // AirPods calibration is pending; no hardware is requested by this fixture.
        h.coordinator.prepareRuleBindings = { _ in true }
        let air = ProtectionPreset.headTurn.rule()
        let camera = ProtectionPreset.headTurn.rule(source: .camera)
        try h.coordinator.saveRules([air, camera]); await h.settle()
        XCTAssertEqual(h.model.trackingSource, .airPods)
        XCTAssertEqual(cameras.count, 1, "An AirPods calibration prerequisite must not block the camera rule")
        for n in 0...14 {
            clock = 1 + Double(n) * 0.1; h.now = clock
            cameras[0].completion(.success(NearbyFaceSample(count: 1, capturedAt: clock,
                faces: [CameraFace(bounds: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3), yaw: 0, pitch: 0)])))
            await h.settle()
        }
        XCTAssertTrue(tracker.rulePolicies[camera.id]!.calibrated)
        for n in 0...10 {
            clock = 2.5 + Double(n) * 0.1; h.now = clock
            cameras[0].completion(.success(NearbyFaceSample(count: 1, capturedAt: clock,
                faces: [CameraFace(bounds: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3), yaw: 0.8, pitch: 0)])))
            await h.settle()
        }
        XCTAssertEqual(h.coordinator.plan.activeRules.map(\.id), [camera.id])
        h.coordinator.pause()
        XCTAssertTrue(cameras[0].stopped)
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        h.coordinator.resume(); await h.settle()
        XCTAssertEqual(cameras.count, 2)
        XCTAssertTrue(h.coordinator.plan.hasProtection, "Resuming calibrated camera protection must cover while it recalibrates")
        for n in 0...14 {
            clock = 3.6 + Double(n) * 0.1; h.now = clock
            cameras[0].completion(.success(NearbyFaceSample(count: 1, capturedAt: clock,
                faces: [CameraFace(bounds: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3), yaw: 0, pitch: 0)])))
            await h.settle()
        }
        XCTAssertFalse(tracker.rulePolicies[camera.id]!.calibrated)
        XCTAssertTrue(h.coordinator.plan.hasProtection, "A previous camera generation must not clear the resumed rule")
        XCTAssertTrue(h.coordinator.document.rules.allSatisfy(\.isEnabled))
    }
    @MainActor func testPauseIntentUsesGlobalRuleStateAndResumeRestoresManualProtection() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish(); QuietGlassIntentBridge.model = nil }
        QuietGlassIntentBridge.model = h.model
        h.model.toggleInstantShield()
        let rules = h.coordinator.document.rules
        _ = try await PauseQuietGlassIntent().perform()
        XCTAssertEqual(h.coordinator.plan.state, .paused(until: nil))
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        XCTAssertEqual(h.coordinator.document.rules, rules)
        h.coordinator.resume()
        XCTAssertTrue(h.coordinator.plan.hasProtection)
    }
    @MainActor func testMigrationFailurePreservesPreferencesAndDoesNotStartLegacyProtection() throws {
        let suite = "QuietGlass.MigrationFailure.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(Data("broken document".utf8), forKey: ProtectionStore.documentKey)
        preferences.set(true, forKey: "nearbyEnabled")
        preferences.set(true, forKey: "privacyScanEnabled")
        let original = preferences.persistentDomain(forName: suite)! as NSDictionary
        let model = AppModel(preferences: preferences, executor: RuleApplicationExecutor(), screenAccess: { true },
                             cameraPermission: { true }, runsRuleTimer: false, startsEventSources: false)
        defer { model.shutdown() }
        XCTAssertNil(model.protectionCoordinator)
        XCTAssertNotNil(model.captureNotice)
        model.start(); model.nearby.restore(); model.toggleInstantShield()
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.nearby.wantsMonitoring)
        XCTAssertFalse(model.nearby.enabled)
        XCTAssertEqual(preferences.persistentDomain(forName: suite)! as NSDictionary, original)
    }
    @MainActor func testClosingAWindowRemovesOnlyItsSessionProtectionRules() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        let source = try XCTUnwrap(h.model.privacy.ruleSources)
        let first = ProtectedWindowRef(bundleID: "example.editor", windowID: 7, ownerPID: 9)
        let second = ProtectedWindowRef(bundleID: "example.editor", windowID: 8, ownerPID: 9)
        source.protect(reference: first, name: "Editor", rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        source.protect(reference: second, name: "Editor", rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        source.removeClosedWindows(existing: [(8, 9)])
        XCTAssertEqual(h.model.privacy.protectedAreas.map(\.window.id), [8])
        XCTAssertNotNil(source.manualRule(scope: .allDisplays), "Closing a selected window must not delete other rules")
    }
    @MainActor func testSimultaneousNearbyRulesUseIndependentDetectionFromOneCameraSample() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        let any = ProtectionRule(name: "Any face", trigger: .extraFace(detection: .anyFace), scope: .allDisplays,
                                 action: .warnOnly(delay: 5, sound: false), guards: [.permission(.camera)])
        let facing = ProtectionRule(name: "Facing", trigger: .extraFace(detection: .facingScreen), scope: .allDisplays,
                                    action: .blur(BlurParameters(), peek: nil), guards: [.permission(.camera)])
        try h.coordinator.saveRules([any, facing]); await h.settle()
        XCTAssertEqual(h.cameras.count, 1)
        let faces = [CameraFace(bounds: CGRect(x: 0.4, y: 0.3, width: 0.3, height: 0.3), yaw: 0, pitch: 0),
                     CameraFace(bounds: CGRect(x: 0, y: 0.3, width: 0.1, height: 0.1), yaw: 1.2, pitch: 0)]
        for time in [1.0, 1.4, 1.8] {
            h.now = time
            let count = h.executor.plans.count
            h.cameras[0].completion(.success(NearbyFaceSample(count: 2, capturedAt: time, faces: faces)))
            await h.settle()
            XCTAssertEqual(h.executor.plans.count, count + 1, "All detection modes share one event batch")
        }
        XCTAssertEqual(h.coordinator.plan.warnings.map(\.id), [any.id])
        XCTAssertFalse(h.coordinator.plan.hasProtection, "A face turned away must not activate the facing-screen rule")
        XCTAssertEqual(h.cameras.count, 1)
        try h.coordinator.setEnabled(any.id, false); await h.settle()
        XCTAssertEqual(h.cameras.count, 1, "Removing one detection rule must not restart the shared camera")
        XCTAssertTrue(h.coordinator.plan.warnings.isEmpty)
    }
    @MainActor func testHealthyNearbyBlurMonitoringPrewarmsTheUnifiedCapturePlan() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.model.setNearbyResponse(.blur); h.model.setNearbyPeople(true); await h.settle()
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        XCTAssertEqual(h.coordinator.plan.captureDisplayIDs, [1])
        XCTAssertEqual(h.coordinator.plan.displays[0].blur.radius, 52)
        XCTAssertNotNil(h.model.privacy.ruleSources)
        XCTAssertEqual(h.executor.plans.last?.captureDisplayIDs, [1])
    }
    @MainActor func testRecordedShortcutsWriteRuleBindingsAndRejectUnavailableChanges() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .control],
            timestamp: 0, windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        var edited = try XCTUnwrap(h.coordinator.document.rules.first { if case .manual = $0.trigger { return $0.scope == .allDisplays }; return false })
        edited.trigger = .manual(shortcut: try XCTUnwrap(ShortcutBinding.recorded(from: event)))
        try h.coordinator.saveRules(h.coordinator.document.rules.map { $0.id == edited.id ? edited : $0 })
        let rule = try XCTUnwrap(h.coordinator.document.rules.first { $0.id == edited.id })
        if case .manual(let shortcut) = rule.trigger { XCTAssertEqual(shortcut?.keyCode, 18) } else { XCTFail("Missing manual shortcut") }
        XCTAssertNil(h.preferences.object(forKey: "privacyShortcutKey"))
        let before = h.coordinator.document
        h.coordinator.prepareRuleBindings = { _ in false }
        let second = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .control],
            timestamp: 0, windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        edited.trigger = .manual(shortcut: try XCTUnwrap(ShortcutBinding.recorded(from: second)))
        XCTAssertThrowsError(try h.coordinator.saveRules(h.coordinator.document.rules.map { $0.id == edited.id ? edited : $0 }))
        XCTAssertEqual(h.coordinator.document, before)
    }
    @MainActor func testRealManualEntrypointsSubmitPlansAndGlobalCommandsClearThem() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        var manual = try XCTUnwrap(h.model.privacy.ruleSources?.manualRule(scope: .allDisplays))
        manual.action = .blur(h.coordinator.document.preferences.defaultBlur, peek: .hold(ShortcutBinding(keyCode: 49, modifiers: 256, label: "⌘Space")))
        var rules = h.coordinator.document.rules
        rules[rules.firstIndex(where: { $0.id == manual.id })!] = manual
        try h.coordinator.saveRules(rules)
        h.model.toggleInstantShield()
        XCTAssertTrue(h.coordinator.plan.hasProtection)
        XCTAssertEqual(h.executor.plans.last?.displays.first?.fullScreenCoverage, 1)
        XCTAssertNotNil(h.model.privacy.ruleSources, "The selection adapter must submit protection through rules")
        h.model.privacy.setPeeking(true)
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        h.model.privacy.setPeeking(false)
        h.model.privacy.pauseProtection()
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        h.model.privacy.resume()
        XCTAssertTrue(h.coordinator.plan.hasProtection)
        h.model.previewShield()
        XCTAssertTrue(h.coordinator.plan.activeRules.contains { $0.name == "Preview" })
        h.model.dismissShield()
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        XCTAssertTrue(h.coordinator.plan.activeRules.isEmpty)
        XCTAssertFalse(h.model.previewing)
        XCTAssertEqual(h.preferences.bool(forKey: "nearbyEnabled"), false)
    }

    @MainActor func testRuleSettingsAndProfileChangesLeaveLegacyKeysReadOnly() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.model.comfort = 25
        h.model.privacy.scanEnabled = true
        h.model.privacy.scanOptions = [.emailAddresses, .paymentCards]
        h.model.privacy.savePhrases("Account label")
        h.model.demoMode = true
        XCTAssertEqual(h.preferences.double(forKey: "comfort"), 17)
        XCTAssertFalse(h.preferences.bool(forKey: "privacyScanEnabled"))
        XCTAssertNil(h.preferences.object(forKey: "privacyScanOptions"))
        XCTAssertNil(h.preferences.object(forKey: "privacyCustomPhrases"))
        XCTAssertFalse(h.preferences.bool(forKey: "includeBlurInCaptures"))
        let scan = try XCTUnwrap(h.coordinator.document.rules.first { if case .sensitiveText = $0.trigger { return true }; return false })
        XCTAssertEqual(scan.trigger, .sensitiveText(types: [.emailAddresses, .paymentCards], phrases: ["Account label"]))
        XCTAssertTrue(scan.isEnabled)
        h.model.applyProfile(.publicSpace)
        XCTAssertEqual(h.coordinator.document.preferences.defaultBlur, BlurParameters(radius: 45, comfort: 8, transition: 12))
        XCTAssertEqual(h.preferences.double(forKey: "blur"), 52)
        let reloaded = try ProtectionStore(storage: h.preferences).loadOrMigrate()
        XCTAssertEqual(reloaded, h.coordinator.document)
    }

    @MainActor func testSelectedWindowAndRegionUseRulesAndFocusCarvesForeground() throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        let ref = ProtectedWindowRef(bundleID: "example.editor", windowID: 7, ownerPID: 9)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        h.coordinator.send(.windows([ProtectionWindow(reference: ref, frame: frame)], activeWindow: frame, activeBundleID: ref.bundleID))
        let source = try XCTUnwrap(h.model.privacy.ruleSources)
        source.protect(reference: ref, name: "Editor")
        XCTAssertEqual(h.coordinator.plan.displays[0].regions.first?.rectangle, frame)
        source.protect(reference: ref, name: "Editor", rectangle: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(h.model.privacy.protectedAreas.count, 1)
        XCTAssertEqual(h.coordinator.plan.displays[0].regions.count, 2)
        h.model.toggleInstantShield(); h.model.setFocus(true)
        XCTAssertEqual(h.coordinator.plan.displays[0].excludedRegions, [frame])
        XCTAssertTrue(h.coordinator.plan.activeRules.contains { $0.name == "Focus" })
        h.model.dismissShield()
        XCTAssertTrue(h.model.privacy.protectedAreas.isEmpty)
    }

    @MainActor func testNearbySamplesUseEngineWarningDeadlineAndPauseWithoutWritingLegacyPreferences() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.model.setNearbyPeople(true); await h.settle()
        XCTAssertEqual(h.cameras.count, 1)
        await h.face(2, at: 1); await h.face(2, at: 1.4)
        XCTAssertEqual(h.coordinator.plan.warnings.first?.secondsRemaining, 120)
        XCTAssertEqual(h.nearby.warningSecondsRemaining, 120)
        XCTAssertFalse(h.nearby.covered)
        h.now = 121.4; h.coordinator.send(.tick)
        XCTAssertTrue(h.nearby.covered)
        XCTAssertEqual(h.coordinator.plan.activeRules.first?.reason, .warningEscalated)
        h.nearby.pauseForFiveMinutes()
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        XCTAssertTrue(h.cameras[0].stopped)
        XCTAssertFalse(h.preferences.bool(forKey: "nearbyEnabled"))
        XCTAssertNil(h.preferences.object(forKey: "nearbyPauseUntil"))
        h.nearby.resumeNow(); await h.settle()
        XCTAssertEqual(h.cameras.count, 2)
        h.model.dismissShield()
        XCTAssertTrue(h.nearby.wantsMonitoring)
        XCTAssertFalse(h.nearby.enabled)
        XCTAssertTrue(h.coordinator.document.rules.filter { if case .extraFace = $0.trigger { return true }; return false }.allSatisfy(\.isEnabled))
    }

    @MainActor func testManualUseAndClearingKeepAutomaticSetupsEnabled() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        h.coordinator.prepareRuleBindings = { _ in true }
        h.model.setNearbyPeople(true); await h.settle()
        let automaticIDs = h.coordinator.document.rules.filter { if case .extraFace = $0.trigger { return true }; return false }.map(\.id)
        XCTAssertFalse(automaticIDs.isEmpty)
        await h.face(2, at: 1); await h.face(2, at: 1.4)
        h.now = 121.4; h.coordinator.send(.tick)
        XCTAssertTrue(h.coordinator.plan.hasProtection)

        let manual = try XCTUnwrap(h.model.privacy.ruleSources?.manualRule(scope: .allDisplays))
        h.coordinator.toggleManual(manual.id)
        XCTAssertTrue(h.coordinator.isManuallyActivated(manual.id))
        for id in automaticIDs { XCTAssertTrue(try XCTUnwrap(h.coordinator.document.rules.first { $0.id == id }).isEnabled) }

        h.model.dismissShield()
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        for id in automaticIDs { XCTAssertTrue(try XCTUnwrap(h.coordinator.document.rules.first { $0.id == id }).isEnabled) }
        XCTAssertTrue(h.nearby.wantsMonitoring)

        XCTAssertFalse(h.model.automaticDetectionEnabled)
        h.model.setAutomaticDetection(true); await h.settle()
        XCTAssertTrue(h.nearby.enabled)
    }

    @MainActor func testWarnOnlyDoesNotEscalateUntilRealBlurNowAction() async throws {
        let h = try RuleApplicationHarness(); defer { h.finish() }
        var rules = h.coordinator.document.rules
        let index = try XCTUnwrap(rules.firstIndex { if case .extraFace = $0.trigger { return true }; return false })
        rules[index].isEnabled = true; rules[index].action = .warnOnly(delay: 5, sound: false)
        try h.coordinator.saveRules(rules); await h.settle()
        await h.face(2, at: 1); await h.face(2, at: 1.4)
        h.now = 500; h.coordinator.send(.tick)
        XCTAssertFalse(h.coordinator.plan.hasProtection)
        h.model.blurNearbyNow()
        XCTAssertTrue(h.coordinator.plan.hasProtection)
        XCTAssertEqual(h.coordinator.document.rules[index].action, .warnOnly(delay: 5, sound: false))
    }
}
