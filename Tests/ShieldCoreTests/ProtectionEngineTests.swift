import XCTest
@testable import ShieldCore

final class ProtectionEngineTests: XCTestCase {
    func testNearbyWarningEscalatesOnlyOnItsSelectedDisplayRegionAndTracksDisplayGeometry() throws {
        let normalized = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        let rule = ProtectionRule(name: "Selected", trigger: .extraFace(detection: .anyFace),
            scope: .displayRegion(id: 2, normalizedRect: normalized), action: .warnOnly(delay: 10, sound: false))
        var engine = try ProtectionEngine(rules: [rule])
        engine.send(.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                              ProtectionDisplay(id: 2, frame: CGRect(x: -400, y: 100, width: 400, height: 300))]), at: 0)
        engine.send(.permission(.screen, granted: true), at: 0)
        engine.send(.escapeAvailability(true), at: 0)
        let warning = engine.send(.nearby(.anyFace, active: true, ownerVerified: false), at: 1)
        XCTAssertFalse(warning.hasProtection); XCTAssertEqual(warning.warnings.map(\.id), [rule.id])
        let covered = engine.send(.blurNow(rule.id), at: 2)
        XCTAssertFalse(covered.displays[0].hasProtection)
        XCTAssertEqual(covered.displays[1].regions.map(\.rectangle), [CGRect(x: -300, y: 160, width: 200, height: 180)])
        let resized = engine.send(.displays([ProtectionDisplay(id: 2, frame: CGRect(x: 1000, y: -600, width: 800, height: 600))]), at: 3)
        XCTAssertEqual(resized.displays[0].regions.map(\.rectangle), [CGRect(x: 1200, y: -480, width: 400, height: 360)])
        XCTAssertFalse(engine.send(.displays([]), at: 4).hasProtection)
        XCTAssertEqual(try JSONDecoder().decode(ProtectionRule.self, from: JSONEncoder().encode(rule)), rule)
    }

    func testCalibratedCameraStaysCoveredWhenItsPermissionIsLost() throws {
        let rule = ProtectionRule(name: "Camera", trigger: .headTurn(source: .camera), scope: .allDisplays,
            guards: [.permission(.camera), .permission(.screen), .calibrationRequired])
        var engine = try ready([rule])
        engine.send(.permission(.camera, granted: false), at: 0)
        XCTAssertFalse(engine.send(.headRuleCoverage(rule.id, coverage: 1, displays: [:], calibrated: false), at: 0).hasProtection)
        XCTAssertTrue(engine.send(.headRuleCoverage(rule.id, coverage: 1, displays: [:], calibrated: true), at: 1).hasProtection)
        XCTAssertFalse(engine.send(.permission(.screen, granted: false), at: 2).hasProtection)
    }
    func testRememberedManualRegionRestoresByTitleButHonorsClearAndEscape() throws {
        let digest = String(repeating: "a", count: 64)
        let ref = ProtectedWindowRef(bundleID: "test.app", titleDigest: digest)
        let rule = ProtectionRule(name: "Remembered", trigger: .manual(shortcut: nil),
            scope: .region(ref, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), persistence: .rememberWindowTitle))
        var engine = try ready([rule])
        func windows(_ id: UInt32) -> ProtectionEvent {
            .windows([ProtectionWindow(reference: ProtectedWindowRef(bundleID: "test.app", windowID: id, ownerPID: 1, titleDigest: digest), frame: CGRect(x: 0, y: 0, width: 100, height: 100))], activeWindow: nil, activeBundleID: nil)
        }
        XCTAssertTrue(engine.send(windows(1), at: 0).hasProtection)
        XCTAssertFalse(engine.send(.manual(rule.id, active: false), at: 1).hasProtection)
        XCTAssertFalse(engine.send(windows(1), at: 2).hasProtection, "Geometry polling must not undo a manual clear")
        engine.send(.windows([], activeWindow: nil, activeBundleID: nil), at: 3)
        XCTAssertTrue(engine.send(windows(2), at: 4).hasProtection)
        engine.send(.escape, at: 5)
        XCTAssertFalse(engine.send(windows(3), at: 6).hasProtection)
        XCTAssertTrue(engine.send(.resume, at: 7).hasProtection)
    }
    func testTextAndWindowOverlapUsesCombinedRulePriorityForParameters() throws {
        let reference = ProtectedWindowRef(bundleID: "test.editor", windowID: 1)
        let window = ProtectionRule(name: "Window", trigger: .manual(shortcut: nil), scope: .window(reference),
                                   action: .blur(BlurParameters(radius: 10), peek: nil))
        let text = ProtectionRule(name: "Text", priority: 100, trigger: .sensitiveText(types: [.credentials], phrases: []), scope: .detectedText,
                                 action: .blur(BlurParameters(radius: 50), peek: nil))
        var engine = try ready([window, text])
        engine.send(.windows([ProtectionWindow(reference: reference, frame: CGRect(x: 0, y: 0, width: 100, height: 100))], activeWindow: nil, activeBundleID: nil), at: 0)
        engine.send(.manual(window.id, active: true), at: 0)
        let plan = engine.send(.detectedText(text.id, regions: [1: [CGRect(x: 20, y: 20, width: 50, height: 50)]]), at: 0)
        XCTAssertEqual(plan.displays[0].orderedRegions.map(\.ruleID), [text.id, window.id])
        XCTAssertEqual(plan.displays[0].orderedRegions.map { $0.blur.radius }, [50, 10])
    }
    func testOwnerVerificationCannotRevealWhenCameraPermissionIsLost() throws {
        let rule = ProtectionRule(name: "Owner", trigger: .extraFace(detection: .anyFace), scope: .allDisplays,
                                  action: .blur(BlurParameters(), peek: nil), guards: [.ownerVerification, .permission(.camera), .permission(.screen)])
        var engine = try ready([rule])
        engine.send(.nearby(.anyFace, active: false, ownerVerified: false), at: 0)
        let lost = engine.send(.permission(.camera, granted: false), at: 1)
        XCTAssertTrue(lost.hasProtection)
        XCTAssertEqual(lost.activeRules.first?.reason, .ownerUnverified)
        XCTAssertFalse(engine.send(.permission(.screen, granted: false), at: 2).hasProtection)
    }
    func testIndependentHeadSamplesKeepRuleScopeParametersAndCalibration() throws {
        let first = ProtectionRule(name: "First", trigger: .headTurn(source: .airPods), scope: .display(ids: [1]),
                                   action: .blur(BlurParameters(radius: 10), peek: nil), guards: [.calibrationRequired])
        let second = ProtectionRule(name: "Second", trigger: .headTurn(source: .airPods), scope: .display(ids: [2]),
                                    action: .blur(BlurParameters(radius: 50), peek: nil), guards: [.calibrationRequired])
        var engine = try ready([first, second])
        engine.send(.headRuleCoverage(first.id, coverage: 0.4, displays: [:], calibrated: true), at: 0)
        let plan = engine.send(.headRuleCoverage(second.id, coverage: 0, displays: [:], calibrated: true), at: 0)
        XCTAssertEqual(plan.displays[0].fullScreenCoverage, 0.4)
        XCTAssertEqual(plan.displays[0].blur.radius, 10)
        XCTAssertEqual(plan.displays[1].fullScreenCoverage, 0)
        let both = engine.send(.headRuleCoverage(second.id, coverage: 0.8, displays: [:], calibrated: true), at: 1)
        XCTAssertEqual(both.displays[1].fullScreenCoverage, 0.8)
        XCTAssertEqual(both.displays[1].blur.radius, 50)
        let unavailable = engine.send(.headRuleCoverage(first.id, coverage: 1, displays: [:], calibrated: false), at: 2)
        XCTAssertEqual(unavailable.displays[0].fullScreenCoverage, 0)
        XCTAssertEqual(unavailable.activeRules.map(\.id), [second.id])
    }
    func testPeekingFocusDoesNotSuppressAnAutomaticHeadRule() throws {
        let head = ProtectionPreset.headTurn.rule()
        var focus = ProtectionPreset.focus.rule()
        focus.action = .blur(BlurParameters(), peek: .hold(ShortcutBinding(keyCode: 49, modifiers: 6400, label: "Peek")))
        var engine = try ready([head, focus])
        engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 0)
        engine.send(.manual(focus.id, active: true), at: 0)
        let peek = engine.send(.peek(focus.id, held: true), at: 1)
        XCTAssertTrue(peek.hasProtection)
        XCTAssertEqual(peek.activeRules.map(\.id), [head.id])
    }
    func testNearbyBlurPrewarmsOnePlanWithoutClaimingCoverageAndStopsOnPause() throws {
        let rule = ProtectionRule(name: "Nearby", trigger: .extraFace(detection: .anyFace), scope: .allDisplays,
                                  action: .blur(BlurParameters(radius: 52), peek: nil), guards: [.permission(.camera)])
        var engine = try ready([rule])
        let warm = engine.send(.nearbyMonitoring(.anyFace, true), at: 0)
        XCTAssertFalse(warm.hasProtection)
        XCTAssertTrue(warm.activeRules.isEmpty)
        XCTAssertEqual(warm.captureDisplayIDs, [1, 2])
        XCTAssertEqual(warm.displays[0].blur.radius, 52)
        XCTAssertTrue(engine.send(.pause(until: nil), at: 1).captureDisplayIDs.isEmpty)
        engine.send(.resume, at: 2)
        XCTAssertTrue(engine.send(.nearbyMonitoring(.anyFace, false), at: 3).captureDisplayIDs.isEmpty)
    }
    func testManualCoverageIsImmediateWhileHeadCoverageKeepsSmoothTransitions() throws {
        let head = ProtectionPreset.headTurn.rule(), full = manual()
        var engine = try ready([head, full])
        let motion = engine.send(.headCoverage(.airPods, coverage: 0.5, displays: [:], calibrated: true), at: 0)
        XCTAssertTrue(motion.displays[0].animatesCoverage)
        XCTAssertFalse(engine.send(.manual(full.id, active: true), at: 1).displays[0].animatesCoverage)
    }
    func testOCRCaptureDemandRequiresPermissionEscapeAndRunningRule() throws {
        let rule = ProtectionPreset.sensitiveText.rule()
        var engine = try ProtectionEngine(rules: [rule])
        XCTAssertTrue(engine.send(.tick, at: 0).textAnalysisRuleIDs.isEmpty)
        engine.send(.permission(.screen, granted: true), at: 0)
        XCTAssertTrue(engine.send(.tick, at: 0).textAnalysisRuleIDs.isEmpty)
        XCTAssertEqual(engine.send(.escapeAvailability(true), at: 0).textAnalysisRuleIDs, [rule.id])
        XCTAssertTrue(engine.send(.pause(until: nil), at: 1).textAnalysisRuleIDs.isEmpty)
        XCTAssertEqual(engine.send(.resume, at: 2).textAnalysisRuleIDs, [rule.id])
        XCTAssertTrue(engine.send(.escape, at: 3).textAnalysisRuleIDs.isEmpty)
        engine.send(.detectedText(rule.id, regions: [:]), at: 4)
        XCTAssertTrue(engine.send(.tick, at: 4).textAnalysisRuleIDs.isEmpty)
    }

    func testAirPodsRearmAfterCenterButCameraRemainsCleared() throws {
        let airPods = ProtectionPreset.headTurn.rule(source: .airPods)
        let camera = ProtectionPreset.headTurn.rule(source: .camera)
        var engine = try ready([airPods, camera])
        engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 0)
        engine.send(.headCoverage(.camera, coverage: 1, displays: [:], calibrated: true), at: 0)
        engine.send(.escape, at: 1)
        engine.send(.headCoverage(.camera, coverage: 0, displays: [:], calibrated: true), at: 2)
        XCTAssertFalse(engine.send(.headCoverage(.camera, coverage: 1, displays: [:], calibrated: true), at: 3).hasProtection)
        engine.send(.headCoverage(.airPods, coverage: 0, displays: [:], calibrated: true), at: 4)
        let plan = engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 5)
        XCTAssertTrue(plan.hasProtection)
        XCTAssertEqual(plan.activeRules.map(\.id), [airPods.id])
    }

    func testEvaluationStaysWithinFrameBudgetWith100ActiveRules() throws {
        let rules = (0..<100).map { manual(priority: $0) }
        var engine = try ready(rules)
        for rule in rules { engine.send(.manual(rule.id, active: true), at: 0) }
        let frames = 300
        let start = ProcessInfo.processInfo.systemUptime
        for frame in 0..<frames {
            let plan = engine.send(.tick, at: Double(frame) / 60)
            XCTAssertEqual(plan.activeRules.count, 100)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / Double(frames)
        print("Rule evaluation: 100 active rules, 2 displays, average \(average * 1000) ms/frame")
        XCTAssertLessThan(average, 0.004, "Rule evaluation must leave most of a 60 Hz frame for rendering")
    }
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let ref = ProtectedWindowRef(bundleID: "example.editor", windowID: 7, ownerPID: 8)
    private func ready(_ rules: [ProtectionRule]) throws -> ProtectionEngine {
        var engine = try ProtectionEngine(rules: rules)
        engine.send(.displays([ProtectionDisplay(id: 1, frame: frame), ProtectionDisplay(id: 2, frame: frame.offsetBy(dx: 1000, dy: 0))]), at: 0)
        engine.send(.permission(.screen, granted: true), at: 0)
        engine.send(.permission(.camera, granted: true), at: 0)
        engine.send(.permission(.motion, granted: true), at: 0)
        engine.send(.escapeAvailability(true), at: 0)
        return engine
    }
    private func manual(scope: ProtectionScope = .allDisplays, priority: Int = 0, created: TimeInterval = 0) -> ProtectionRule {
        ProtectionRule(name: "Manual", priority: priority, createdAt: Date(timeIntervalSince1970: created), trigger: .manual(shortcut: nil), scope: scope)
    }

    func testManualAndAutomaticFullscreenDominateRegionalOutputWithoutDuplicatePlans() throws {
        let full = manual(), window = manual(scope: .window(ref)), text = ProtectionPreset.sensitiveText.rule()
        let nearby = ProtectionRule(name: "Nearby", trigger: .extraFace(detection: .anyFace), scope: .allDisplays)
        var engine = try ready([full, window, text, nearby])
        engine.send(.windows([ProtectionWindow(reference: ref, frame: CGRect(x: 10, y: 20, width: 200, height: 300))], activeWindow: nil, activeBundleID: ref.bundleID), at: 0)
        engine.send(.manual(window.id, active: true), at: 1)
        engine.send(.detectedText(text.id, regions: [1: [CGRect(x: 40, y: 60, width: 20, height: 20)]]), at: 1)
        let plan = engine.send(.manual(full.id, active: true), at: 1)
        XCTAssertEqual(plan.displays.count, 2)
        XCTAssertTrue(plan.displays.allSatisfy { $0.fullScreenCoverage == 1 })
        XCTAssertEqual(Set(plan.activeRules.map(\.id)), [full.id, window.id, text.id])
        engine.send(.manual(full.id, active: false), at: 2)
        let automatic = engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 2)
        XCTAssertTrue(automatic.displays.allSatisfy { $0.fullScreenCoverage == 1 })
        XCTAssertEqual(automatic.activeRules.first?.id, nearby.id)
    }

    func testFocusCarvesActiveWindowOutOfFullscreenAndSuspendsHeadOnly() throws {
        let full = manual(), focus = ProtectionPreset.focus.rule(), head = ProtectionPreset.headTurn.rule()
        var engine = try ready([full, focus, head])
        let active = CGRect(x: 100, y: 100, width: 400, height: 300)
        engine.send(.windows([], activeWindow: active, activeBundleID: ref.bundleID), at: 0)
        engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 1)
        engine.send(.manual(full.id, active: true), at: 1)
        let plan = engine.send(.manual(focus.id, active: true), at: 1)
        XCTAssertEqual(plan.displays[0].fullScreenCoverage, 1)
        XCTAssertEqual(plan.displays[0].excludedRegions, [active])
        XCTAssertTrue(plan.displays[0].regions.allSatisfy { !$0.rectangle.intersects(active) })
        XCTAssertFalse(plan.activeRules.contains { $0.id == head.id })
        XCTAssertTrue(plan.activeRules.contains { $0.id == full.id })
    }

    func testRegionsAndTextUnionWithDisplayClippingAndWindowOcclusion() throws {
        let window = manual(scope: .window(ref))
        let region = manual(scope: .region(ref, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1), persistence: .session))
        let text = ProtectionPreset.sensitiveText.rule()
        var engine = try ready([window, region, text])
        let occluder = CGRect(x: 0, y: 0, width: 100, height: 800)
        engine.send(.windows([ProtectionWindow(reference: ref, frame: frame, occluders: [occluder])], activeWindow: nil, activeBundleID: ref.bundleID), at: 0)
        engine.send(.manual(window.id, active: true), at: 1)
        engine.send(.manual(region.id, active: true), at: 1)
        let plan = engine.send(.detectedText(text.id, regions: [1: [CGRect(x: 990, y: 50, width: 50, height: 20)]]), at: 1)
        XCTAssertEqual(plan.displays[0].regions.count, 2)
        XCTAssertTrue(plan.displays[0].regions.allSatisfy { !$0.rectangle.intersects(occluder) })
        XCTAssertEqual(plan.displays[0].textRegions.first?.rectangle.width, 10)
        XCTAssertTrue(plan.displays[1].activeRules.isEmpty)
    }

    func testEscapeClearsAllAndAutomaticCameraRulesRequireExplicitResume() throws {
        let full = manual(), nearby = ProtectionPreset.nearby.rule()
        var engine = try ready([full, nearby])
        engine.send(.manual(full.id, active: true), at: 0)
        engine.send(.nearby(.facingScreen, active: true, ownerVerified: true), at: 0)
        let clear = engine.send(.escape, at: 1)
        XCTAssertFalse(clear.hasProtection); XCTAssertTrue(clear.warnings.isEmpty)
        XCTAssertFalse(engine.send(.tick, at: 200).hasProtection)
        XCTAssertTrue(engine.send(.manual(full.id, active: true), at: 201).hasProtection)
        engine.send(.manual(full.id, active: false), at: 202)
        engine.send(.nearby(.facingScreen, active: false, ownerVerified: true), at: 202)
        XCTAssertEqual(engine.send(.nearby(.facingScreen, active: true, ownerVerified: true), at: 203).warnings.count, 0)
        XCTAssertEqual(engine.send(.resume, at: 204).warnings.count, 1)
    }

    func testGlobalPauseAndSuspendDominateManualAndAutomaticAndResumeKeepsSources() throws {
        let full = manual()
        var engine = try ready([full])
        engine.send(.manual(full.id, active: true), at: 0)
        XCTAssertFalse(engine.send(.pause(until: 10), at: 1).hasProtection)
        XCTAssertTrue(engine.send(.tick, at: 10).hasProtection)
        XCTAssertFalse(engine.send(.suspend, at: 11).hasProtection)
        XCTAssertTrue(engine.send(.wake, at: 12).hasProtection)
        engine.send(.pause(until: nil), at: 13)
        engine.send(.suspend, at: 14)
        XCTAssertFalse(engine.send(.wake, at: 15).hasProtection)
        XCTAssertTrue(engine.send(.resume, at: 16).hasProtection)
    }

    func testPeekNeverClearsNearbyAndWorksOnlyForHeldManualRule() throws {
        let binding = ShortcutBinding(keyCode: 49, modifiers: 6400, label: "Peek")
        var full = manual(); full.action = .blur(BlurParameters(), peek: .hold(binding))
        let nearby = ProtectionRule(name: "Nearby", trigger: .extraFace(detection: .anyFace), scope: .allDisplays)
        var engine = try ready([full, nearby])
        engine.send(.manual(full.id, active: true), at: 0)
        XCTAssertFalse(engine.send(.peek(full.id, held: true), at: 1).hasProtection)
        XCTAssertTrue(engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 2).hasProtection)
        engine.send(.nearby(.anyFace, active: false, ownerVerified: true), at: 3)
        XCTAssertTrue(engine.send(.peek(full.id, held: false), at: 4).hasProtection)
    }

    func testWarningEscalatesOnceAndChangingDelayCannotUncover() throws {
        var rule = ProtectionPreset.nearby.rule()
        var engine = try ready([rule])
        XCTAssertEqual(engine.send(.nearby(.facingScreen, active: true, ownerVerified: true), at: 1).warnings.first?.secondsRemaining, 120)
        XCTAssertEqual(engine.send(.tick, at: 60).warnings.first?.secondsRemaining, 61)
        XCTAssertTrue(engine.send(.tick, at: 121).hasProtection)
        rule.action = .warnThenBlur(delay: 3600, sound: true)
        try engine.replaceRules([rule])
        let plan = engine.send(.tick, at: 122)
        XCTAssertTrue(plan.hasProtection); XCTAssertTrue(plan.warnings.isEmpty)
        XCTAssertEqual(plan.activeRules.first?.reason, .warningEscalated)
        XCTAssertFalse(engine.send(.nearby(.facingScreen, active: false, ownerVerified: true), at: 123).hasProtection)
    }

    func testWarnOnlyNeverAutomaticallyBlursButBlurNowUsesOriginalWindowScope() throws {
        var rule = ProtectionPreset.nearby.rule()
        rule.scope = .window(ref); rule.action = .warnOnly(delay: 5, sound: false)
        var engine = try ready([rule])
        engine.send(.windows([ProtectionWindow(reference: ref, frame: frame)], activeWindow: nil, activeBundleID: ref.bundleID), at: 0)
        engine.send(.nearby(.facingScreen, active: true, ownerVerified: true), at: 0)
        let warning = engine.send(.tick, at: 100)
        XCTAssertFalse(warning.hasProtection); XCTAssertEqual(warning.warnings.count, 1)
        let plan = engine.send(.blurNow(rule.id), at: 101)
        XCTAssertTrue(plan.hasProtection); XCTAssertEqual(plan.displays[0].fullScreenCoverage, 0)
        XCTAssertEqual(plan.displays[0].regions.first?.rectangle, frame)
        XCTAssertEqual(engine.rules.count, 1)
    }

    func testOwnerVerificationFailsClosedAndClearsOnlyWhenVerifiedWithoutExtraFace() throws {
        var rule = ProtectionPreset.nearby.rule()
        rule.action = .blur(BlurParameters(), peek: nil); rule.guards.append(.ownerVerification)
        var engine = try ready([rule])
        let unknown = engine.send(.nearby(.facingScreen, active: false, ownerVerified: false), at: 0)
        XCTAssertTrue(unknown.hasProtection); XCTAssertEqual(unknown.activeRules.first?.reason, .ownerUnverified)
        XCTAssertFalse(engine.send(.nearby(.facingScreen, active: false, ownerVerified: true), at: 1).hasProtection)
        XCTAssertTrue(engine.send(.nearby(.facingScreen, active: true, ownerVerified: true), at: 2).hasProtection)
    }

    func testCalibrationScreenPermissionAndEscapeGateActualCoverage() throws {
        let rule = ProtectionPreset.headTurn.rule()
        var engine = try ready([rule])
        XCTAssertFalse(engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: false), at: 0).hasProtection)
        XCTAssertTrue(engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 1).hasProtection)
        XCTAssertFalse(engine.send(.permission(.screen, granted: false), at: 2).hasProtection)
        engine.send(.permission(.screen, granted: true), at: 3)
        XCTAssertFalse(engine.send(.escapeAvailability(false), at: 4).hasProtection)
    }

    func testPerDisplayTrackingAndExplicitScopeStayOnTheirDisplays() throws {
        var rule = ProtectionPreset.headTurn.rule(); rule.scope = .display(ids: [2])
        var engine = try ready([rule])
        let plan = engine.send(.headCoverage(.airPods, coverage: 1, displays: [1: 1, 2: 0.3], calibrated: true), at: 0)
        XCTAssertEqual(plan.displays.map(\.fullScreenCoverage), [0, 0.3])
        XCTAssertTrue(plan.displays[0].activeRules.isEmpty)
    }

    func testPriorityAndCreationTimeResolveParametersDeterministically() throws {
        var old = manual(priority: 5, created: 1), newer = manual(priority: 5, created: 2), high = manual(priority: 9, created: 3)
        old.name = "Old"; newer.name = "New"; high.name = "High"
        old.action = .blur(BlurParameters(radius: 30), peek: nil)
        newer.action = .blur(BlurParameters(radius: 40), peek: nil)
        high.action = .blur(BlurParameters(radius: 50), peek: nil)
        var engine = try ready([newer, old, high])
        engine.send(.manual(newer.id, active: true), at: 0)
        XCTAssertEqual(engine.send(.manual(old.id, active: true), at: 0).displays[0].blur.radius, 30)
        let plan = engine.send(.manual(high.id, active: true), at: 0)
        XCTAssertEqual(plan.displays[0].blur.radius, 50)
        XCTAssertEqual(plan.activeRules.map(\.name), ["High", "Old", "New"])
    }

    func testWindowTitleMatchesDigestAndClosesWithoutStaleCoverage() throws {
        let digest = String(repeating: "b", count: 64)
        let target = ProtectedWindowRef(bundleID: ref.bundleID, titleDigest: digest)
        let rule = ProtectionRule(name: "Saved", trigger: .windowTitle(bundleID: ref.bundleID, titleDigest: digest),
            scope: .region(target, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), persistence: .rememberWindowTitle))
        var engine = try ready([rule])
        XCTAssertFalse(engine.send(.windows([ProtectionWindow(reference: ref, frame: frame)], activeWindow: nil, activeBundleID: nil), at: 0).hasProtection)
        XCTAssertTrue(engine.send(.windows([ProtectionWindow(reference: target, frame: frame)], activeWindow: nil, activeBundleID: nil), at: 1).hasProtection)
        XCTAssertFalse(engine.send(.windows([], activeWindow: nil, activeBundleID: nil), at: 2).hasProtection)
    }

    func testAppHeadPausePreservesManualAndGlobalRulePauseDominatesIt() throws {
        let head = ProtectionPreset.headTurn.rule(), full = manual()
        var pause = ProtectionRule(name: "App", trigger: .appEvent(bundleID: ref.bundleID, event: .activated), scope: .allDisplaysExceptActiveWindow,
                                   action: .pauseOtherProtection(duration: nil, target: .headTurn))
        var engine = try ready([head, full, pause])
        engine.send(.headCoverage(.airPods, coverage: 1, displays: [:], calibrated: true), at: 0)
        engine.send(.manual(full.id, active: true), at: 0)
        let plan = engine.send(.windows([], activeWindow: nil, activeBundleID: ref.bundleID), at: 1)
        XCTAssertTrue(plan.hasProtection); XCTAssertFalse(plan.activeRules.contains { $0.id == head.id })
        pause.action = .pauseOtherProtection(duration: 5)
        try engine.replaceRules([head, full, pause])
        XCTAssertFalse(engine.send(.tick, at: 2).hasProtection)
        let resumed = engine.send(.tick, at: 6)
        XCTAssertTrue(resumed.hasProtection)
        XCTAssertTrue(resumed.activeRules.contains { $0.id == head.id }, "An expired pause must not behave as a focus carve-out")
    }

    func testOvernightTimeAndAppGuardsUseClockAndForegroundApp() throws {
        var rule = manual(); rule.guards = [.appCondition(bundleID: ref.bundleID), .timeWindow(start: DateComponents(hour: 22, minute: 0), end: DateComponents(hour: 6, minute: 0))]
        var engine = try ready([rule])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23))!
        engine.send(.windows([], activeWindow: nil, activeBundleID: ref.bundleID), at: 0, date: night, calendar: calendar)
        XCTAssertTrue(engine.send(.manual(rule.id, active: true), at: 0, date: night, calendar: calendar).hasProtection)
        XCTAssertFalse(engine.send(.tick, at: 1, date: night.addingTimeInterval(8 * 3600), calendar: calendar).hasProtection)
    }
}
