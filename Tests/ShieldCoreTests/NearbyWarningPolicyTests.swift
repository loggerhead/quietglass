import XCTest
@testable import ShieldCore

final class NearbyWarningPolicyTests: XCTestCase {
    private func ready(_ rule: ProtectionRule) throws -> ProtectionEngine {
        var engine = try ProtectionEngine(rules: [rule])
        engine.send(.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]), at: 0)
        engine.send(.permission(.screen, granted: true), at: 0); engine.send(.escapeAvailability(true), at: 0)
        return engine
    }
    private func rule(delay: TimeInterval = 120) -> ProtectionRule {
        ProtectionRule(name: "Nearby", trigger: .extraFace(detection: .anyFace), scope: .allDisplays, action: .warnThenBlur(delay: delay, sound: false))
    }
    func testTwoMinuteDeadlineDoesNotRestartOnRepeatedUpdates() throws {
        let rule = rule(); var engine = try ready(rule)
        XCTAssertEqual(engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 10).warnings.first?.secondsRemaining, 120)
        for time in [11.0, 30, 60, 90, 129.9] { XCTAssertFalse(engine.send(.tick, at: time).hasProtection) }
        let plan = engine.send(.tick, at: 130)
        XCTAssertTrue(plan.hasProtection); XCTAssertEqual(plan.activeRules.first?.reason, .warningEscalated)
    }
    func testResolvedWarningCancelsAndTheNextWarningGetsItsOwnDeadline() throws {
        let rule = rule(); var engine = try ready(rule)
        engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 10)
        XCTAssertTrue(engine.send(.nearby(.anyFace, active: false, ownerVerified: true), at: 90).warnings.isEmpty)
        XCTAssertFalse(engine.send(.tick, at: 300).hasProtection)
        XCTAssertEqual(engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 301).warnings.first?.secondsRemaining, 120)
    }
    func testEditingDelayKeepsTheOriginalStartAndCannotUndoExpiredBlur() throws {
        var rule = rule(); var engine = try ready(rule)
        engine.send(.nearby(.anyFace, active: true, ownerVerified: true), at: 10)
        rule.action = .warnThenBlur(delay: 180, sound: false); try engine.replaceRules([rule])
        XCTAssertEqual(engine.send(.tick, at: 100).warnings.first?.secondsRemaining, 90)
        rule.action = .warnThenBlur(delay: 60, sound: false); try engine.replaceRules([rule])
        XCTAssertTrue(engine.send(.tick, at: 101).hasProtection)
        rule.action = .warnThenBlur(delay: 600, sound: false); try engine.replaceRules([rule])
        let plan = engine.send(.tick, at: 102)
        XCTAssertTrue(plan.hasProtection); XCTAssertEqual(plan.activeRules.first?.reason, .warningEscalated)
    }
    func testDurationBoundsAndInvalidInput() {
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(0), 60)
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(-60), 60)
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(121), 120)
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(100_000), 86_400)
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(.nan), 120)
        XCTAssertEqual(NearbyWarningPolicy.normalizedDelay(.infinity), 120)
    }
}
