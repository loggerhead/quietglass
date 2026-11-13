import XCTest
import ShieldCore
@testable import QuietGlass

final class RuleEditingTests: XCTestCase {
    func testEditorOffersOnlyTheSpecifiedScopeAndActionCombinations() {
        let scopes: [RuleTriggerKind: Set<RuleScopeKind>] = [.manual: [.allDisplays, .displays, .selectedRegion, .window, .region, .focus], .headTurn: [.allDisplays, .displays],
            .extraFace: [.allDisplays, .window, .selectedRegion], .sensitiveText: [.detectedText], .appEvent: [.window, .focus], .windowTitle: [.region]]
        let actions: [RuleTriggerKind: Set<RuleActionKind>] = [.manual: [.blur], .headTurn: [.blur], .extraFace: [.blur, .warnThenBlur, .warnOnly],
            .sensitiveText: [.blur], .appEvent: [.blur, .pause], .windowTitle: [.blur]]
        for trigger in RuleTriggerKind.allCases {
            var draft = RuleDraft(); draft.selectTrigger(trigger)
            XCTAssertEqual(Set(draft.allowedScopes), scopes[trigger])
            XCTAssertEqual(Set(draft.allowedActions), actions[trigger])
        }
    }
    func testInvalidCombinationAndConditionsCannotBeSaved() {
        var draft = RuleDraft()
        draft.selectTrigger(.sensitiveText); draft.scopeKind = .allDisplays
        XCTAssertFalse(draft.canSave)
        draft.scopeKind = .detectedText; draft.ownerVerification = true
        XCTAssertFalse(draft.canSave)
        draft.ownerVerification = false; draft.peekEnabled = true
        XCTAssertFalse(draft.canSave)
        draft.peekEnabled = false; draft.timeEnabled = true; draft.startHour = 24
        XCTAssertFalse(draft.canSave)
        draft.startHour = 22; draft.endHour = 6
        XCTAssertTrue(draft.canSave)
    }
    func testExistingRuleDraftKeepsIdentityAndEveryEditableComponent() {
        let ref = ProtectedWindowRef(bundleID: "example.app", titleDigest: String(repeating: "a", count: 64))
        let rule = ProtectionRule(name: "Saved", priority: 73, trigger: .windowTitle(bundleID: ref.bundleID, titleDigest: ref.titleDigest!),
            scope: .region(ref, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5), persistence: .rememberWindowTitle),
            action: .blur(BlurParameters(radius: 44), peek: nil), guards: [.notPaused, .permission(.screen), .timeWindow(start: DateComponents(hour: 22, minute: 30), end: DateComponents(hour: 6, minute: 15))])
        let draft = RuleDraft(rule: rule)
        XCTAssertEqual(draft.rule, rule)
        XCTAssertTrue(draft.canSave)
    }
    func testChoosingOnActivationKeepsSelectionInternalAndRejectsNoncontinuousPeek() {
        var draft = RuleDraft(); draft.scopeKind = .region; draft.chooseOnActivation = true
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.scopeKind, .region)
        draft.peekEnabled = true
        XCTAssertFalse(draft.canSave)
        draft.peekEnabled = false; draft.selectTrigger(.headTurn)
        XCTAssertTrue(draft.allowedScopes.contains(draft.scopeKind))
    }
}
