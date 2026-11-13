import XCTest
import ShieldCore
@testable import QuietGlass

final class RulePermissionStateTests: XCTestCase {
    func testFreshLaunchUsesCaptureAPIVerificationWhenPreflightReportsFalse() {
        var state = RulePermissionState(screenGranted: false, cameraGranted: true)
        state.screenCheckPending = true
        XCTAssertFalse(state.captureAllowed)
        state.completeScreenCheck(granted: true)
        XCTAssertTrue(state.screenGranted)
        XCTAssertTrue(state.captureAllowed)
        XCTAssertFalse(state.screenCheckPending)
        for _ in 0..<3 {
            state.refresh(screen: false, camera: true)
            XCTAssertTrue(state.screenGranted, "Polling must not erase successful ScreenCaptureKit verification")
        }
        let nextLaunch = RulePermissionState(screenGranted: false, cameraGranted: true)
        XCTAssertFalse(nextLaunch.screenVerifiedByCaptureAPI, "Verification is fresh for every process, never persisted")
    }

    func testRevocationAndCaptureRejectionInvalidateSuccessfulVerification() {
        var state = RulePermissionState(screenGranted: false, cameraGranted: true)
        state.completeScreenCheck(granted: true)
        state.refresh(screen: true, camera: true)
        state.refresh(screen: false, camera: true)
        XCTAssertFalse(state.captureAllowed)
        state.completeScreenCheck(granted: true)
        state.rejectCapture(screenPreflight: false)
        XCTAssertFalse(state.screenVerifiedByCaptureAPI)
        XCTAssertFalse(state.captureAllowed)
    }

    func testAuthoritativeDenialAndUnavailableChecksNeverInventAccess() {
        var state = RulePermissionState(screenGranted: false, cameraGranted: false)
        state.completeScreenCheck(granted: false)
        XCTAssertFalse(state.captureAllowed)
        state.screenCheckPending = true
        state.completeScreenCheck(granted: nil)
        XCTAssertFalse(state.screenCheckPending)
        XCTAssertTrue(state.screenCheckUnavailable)
        XCTAssertFalse(state.captureAllowed)
    }

    func testRejectedCaptureKeepsTheRuleEngineBlockedUntilAccessIsRetried() throws {
        let rule = ProtectionRule(name: "Screen", trigger: .manual(shortcut: nil), scope: .allDisplays, guards: [.permission(.screen)])
        var engine = try ProtectionEngine(rules: [rule])
        var state = RulePermissionState(screenGranted: true, cameraGranted: true)
        engine.send(.displays([ProtectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))]), at: 0)
        engine.send(.permission(.screen, granted: state.captureAllowed), at: 0)
        engine.send(.escapeAvailability(true), at: 0)
        XCTAssertTrue(engine.send(.manual(rule.id, active: true), at: 0).hasProtection)
        state.captureRejected = true
        XCTAssertFalse(engine.send(.permission(.screen, granted: state.captureAllowed), at: 1).hasProtection)
        XCTAssertFalse(state.refresh(screen: true, camera: true))
        XCTAssertFalse(engine.send(.permission(.screen, granted: state.captureAllowed), at: 2).hasProtection)
        XCTAssertTrue(state.refresh(screen: true, camera: true, retryRejectedCapture: true))
        XCTAssertTrue(engine.send(.permission(.screen, granted: state.captureAllowed), at: 3).hasProtection)
    }

    func testGrantAfterRejectedSessionClearsTheOldRejectionWithoutAnotherPrompt() {
        var state = RulePermissionState(screenGranted: false, cameraGranted: true, captureRejected: true)
        XCTAssertTrue(state.refresh(screen: true, camera: true))
        XCTAssertTrue(state.captureAllowed)
        XCTAssertFalse(state.captureRejected)
        XCTAssertTrue(state.missing(in: [.screen, .camera], motionGranted: false).isEmpty)
    }

    func testRejectedCaptureDoesNotMisreportGrantedSystemAccessOrRetryOnEveryPoll() {
        var state = RulePermissionState(screenGranted: true, cameraGranted: true, captureRejected: true)
        XCTAssertFalse(state.refresh(screen: true, camera: true))
        XCTAssertTrue(state.needsCaptureRestart)
        XCTAssertFalse(state.captureAllowed)
        XCTAssertTrue(state.missing(in: [.screen, .camera], motionGranted: false).isEmpty)
        XCTAssertTrue(state.refresh(screen: true, camera: true, retryRejectedCapture: true))
        XCTAssertTrue(state.captureAllowed)
        XCTAssertFalse(state.refresh(screen: true, camera: true, retryRejectedCapture: true))
    }

    func testExternalPermissionChangesUpdateCameraAndScreenIndependently() {
        var state = RulePermissionState(screenGranted: true, cameraGranted: false)
        XCTAssertEqual(state.missing(in: [.screen, .camera], motionGranted: true), [.camera])
        state.refresh(screen: true, camera: true)
        XCTAssertTrue(state.missing(in: [.screen, .camera], motionGranted: true).isEmpty)
        state.refresh(screen: false, camera: true)
        XCTAssertEqual(state.missing(in: [.screen, .camera], motionGranted: true), [.screen])
        XCTAssertFalse(state.captureAllowed)
    }

    func testUnavailableMotionRemainsMissingWhenScreenAndCameraAreGranted() {
        let state = RulePermissionState(screenGranted: true, cameraGranted: true)
        XCTAssertEqual(state.missing(in: [.screen, .camera, .motion], motionGranted: false), [.motion])
    }
}
