import XCTest
@testable import ShieldCore

final class ProtectionRuleTests: XCTestCase {
    private let ref = ProtectedWindowRef(bundleID: "example.editor", titleDigest: String(repeating: "a", count: 64))
    private let shortcut = ShortcutBinding(keyCode: 35, modifiers: 6400, label: "⌃⌥⌘P")

    func testCompleteTriggerScopeActionMatrix() {
        let triggers: [ProtectionTrigger] = [.manual(shortcut: nil), .headTurn(source: .airPods), .extraFace(detection: .anyFace),
            .sensitiveText(types: [.credentials], phrases: []), .appEvent(bundleID: ref.bundleID, event: .activated),
            .windowTitle(bundleID: ref.bundleID, titleDigest: ref.titleDigest!)]
        let scopes: [ProtectionScope] = [.allDisplays, .display(ids: [1]), .window(ref),
            .region(ref, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), persistence: .rememberWindowTitle),
            .detectedText, .allDisplaysExceptActiveWindow, .displayRegion(id: 2, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))]
        let actions: [ProtectionAction] = [.blur(BlurParameters(), peek: nil), .warnThenBlur(delay: 120, sound: true),
                                          .warnOnly(delay: 120, sound: false), .pauseOtherProtection(duration: nil)]
        // Specification plus the requested screenshot-style region scope for manual/nearby rules.
        let legalScopes: [Set<Int>] = [[0, 1, 2, 3, 5, 6], [0, 1], [0, 2, 6], [4], [2, 5], [3]]
        let legalActions: [Set<Int>] = [[0], [0], [0, 1, 2], [0], [0, 3], [0]]
        var checked = 0
        for (t, trigger) in triggers.enumerated() {
            for (s, scope) in scopes.enumerated() {
                for (a, action) in actions.enumerated() {
                    let rule = ProtectionRule(name: "Rule", trigger: trigger, scope: scope, action: action)
                    XCTAssertEqual(ProtectionRuleValidator.validate(rule).isEmpty, legalScopes[t].contains(s) && legalActions[t].contains(a), "T\(t) S\(s) A\(a)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 168)
    }

    func testPeekIsAllowedOnlyOnSustainedManualBlur() {
        for trigger in [ProtectionTrigger.manual(shortcut: nil), .headTurn(source: .camera), .extraFace(detection: .anyFace)] {
            let rule = ProtectionRule(name: "Peek", trigger: trigger, scope: .allDisplays, action: .blur(BlurParameters(), peek: .hold(shortcut)))
            if case .manual = trigger { XCTAssertTrue(ProtectionRuleValidator.validate(rule).isEmpty) }
            else { XCTAssertTrue(ProtectionRuleValidator.validate(rule).contains(.invalidPeek)) }
        }
    }

    func testOwnerGuardIsOnlyLegalForExtraFace() {
        let triggers: [ProtectionTrigger] = [.manual(shortcut: nil), .headTurn(source: .camera), .extraFace(detection: .anyFace),
            .sensitiveText(types: [.credentials], phrases: []), .appEvent(bundleID: "app", event: .activated),
            .windowTitle(bundleID: "app", titleDigest: String(repeating: "a", count: 64))]
        for trigger in triggers {
            let errors = ProtectionRuleValidator.validate(ProtectionRule(name: "Owner", trigger: trigger, scope: .allDisplays, guards: [.ownerVerification]))
            if case .extraFace = trigger { XCTAssertFalse(errors.contains(.invalidOwnerGuard)) }
            else { XCTAssertTrue(errors.contains(.invalidOwnerGuard)) }
        }
    }

    func testRejectsUnusableGeometryAndNonfiniteParameters() {
        for rect in [CGRect.zero, CGRect(x: -0.1, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 2, height: 1), CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            let rule = ProtectionRule(name: "Area", trigger: .manual(shortcut: nil), scope: .region(ref, normalizedRect: rect, persistence: .session))
            XCTAssertTrue(ProtectionRuleValidator.validate(rule).contains(.invalidScope))
        }
        for radius in [Double.nan, .infinity, 0, 71] {
            let rule = ProtectionRule(name: "Blur", trigger: .manual(shortcut: nil), scope: .allDisplays, action: .blur(BlurParameters(radius: radius), peek: nil))
            XCTAssertTrue(ProtectionRuleValidator.validate(rule).contains(.invalidParameters))
        }
        let rule = ProtectionRule(name: "Display", trigger: .manual(shortcut: nil), scope: .display(ids: []))
        XCTAssertTrue(ProtectionRuleValidator.validate(rule).contains(.invalidScope))
        for scope in [ProtectionScope.displayRegion(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)),
                      .displayRegion(id: 1, normalizedRect: CGRect(x: -0.1, y: 0, width: 0.3, height: 0.3)),
                      .displayRegion(id: 1, normalizedRect: .zero)] {
            let invalid = ProtectionRule(name: "Display region", trigger: .manual(shortcut: nil), scope: scope)
            XCTAssertTrue(ProtectionRuleValidator.validate(invalid).contains(.invalidScope))
        }
    }

    func testTimeWindowsRequireAnExplicitValidLocalHourAndMinute() {
        var rule = ProtectionRule(name: "Time", trigger: .manual(shortcut: nil), scope: .allDisplays)
        for components in [DateComponents(), DateComponents(hour: 24, minute: 0), DateComponents(hour: 0, minute: 60), DateComponents(year: 2026, hour: 0, minute: 0)] {
            rule.guards = [.timeWindow(start: components, end: DateComponents(hour: 9, minute: 0))]
            XCTAssertTrue(ProtectionRuleValidator.validate(rule).contains(.invalidTimeWindow))
        }
        rule.guards = [.timeWindow(start: DateComponents(hour: 22, minute: 0), end: DateComponents(hour: 6, minute: 0))]
        XCTAssertTrue(ProtectionRuleValidator.validate(rule).isEmpty)
    }

    func testEveryPresetRoundTripsWithStableIdentityAndCreationTime() throws {
        for preset in ProtectionPreset.allCases {
            let rule = preset.rule()
            XCTAssertTrue(ProtectionRuleValidator.validate(rule).isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(ProtectionRule.self, from: JSONEncoder().encode(rule)), rule)
        }
        let rule = ProtectionRule(name: "Remembered", trigger: .windowTitle(bundleID: ref.bundleID, titleDigest: ref.titleDigest!),
                                  scope: .region(ref, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), persistence: .rememberWindowTitle))
        XCTAssertEqual(try JSONDecoder().decode(ProtectionRule.self, from: JSONEncoder().encode(rule)), rule)
    }

    func testDuplicateIdentityAndInvalidRulesCannotEnterEngine() throws {
        let rule = ProtectionPreset.focus.rule()
        XCTAssertThrowsError(try ProtectionEngine(rules: [rule, rule]))
        var invalid = rule; invalid.action = .warnOnly(delay: 120, sound: false)
        var engine = try ProtectionEngine(rules: [rule])
        XCTAssertThrowsError(try engine.replaceRules([invalid]))
        XCTAssertEqual(engine.rules, [rule])
    }
}
