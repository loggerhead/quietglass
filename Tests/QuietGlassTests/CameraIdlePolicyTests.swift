import XCTest
@testable import QuietGlass

final class CameraIdlePolicyTests: XCTestCase {
    func testFaceActivatesImmediatelyAndThreeEmptySamplesReturnToIdle() {
        var policy = CameraIdlePolicy()
        XCTAssertTrue(policy.idle)
        XCTAssertEqual(policy.framesPerSecond, 5)
        XCTAssertEqual(policy.analysisInterval, 0.2, accuracy: 0.0001)

        XCTAssertTrue(policy.observe(faceCount: 1, at: 1))
        XCTAssertFalse(policy.idle)
        XCTAssertEqual(policy.framesPerSecond, 1 / 0.09, accuracy: 0.0001)
        XCTAssertEqual(policy.analysisInterval, 0.09, accuracy: 0.0001)

        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.1))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.2))
        XCTAssertFalse(policy.idle, "Two empty samples must not downclock")
        XCTAssertTrue(policy.observe(faceCount: 0, at: 1.3))
        XCTAssertTrue(policy.idle)
        XCTAssertEqual(policy.framesPerSecond, 5)
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.4), "Already idle must not reconfigure")
    }

    func testAFaceResetsTheEmptySampleHysteresis() {
        var policy = CameraIdlePolicy()
        XCTAssertTrue(policy.observe(faceCount: 1, at: 1))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.1))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.2))
        XCTAssertFalse(policy.observe(faceCount: 1, at: 1.3), "A face while active must not reconfigure")
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.4))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.5))
        XCTAssertFalse(policy.idle, "The empty-sample count must restart after a face")
        XCTAssertTrue(policy.observe(faceCount: 0, at: 1.6))
        XCTAssertTrue(policy.idle)
    }

    func testExplicitIdleResetClearsHysteresis() {
        var policy = CameraIdlePolicy()
        _ = policy.observe(faceCount: 1, at: 1)
        XCTAssertFalse(policy.idle)
        policy.setIdle(true)
        XCTAssertTrue(policy.idle)
        XCTAssertTrue(policy.hardwareIdle)
        XCTAssertEqual(policy.emptySamples, 0)
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.1))
    }

    func testHardwareDownclocksOnlyAfterTheAggressiveDelay() {
        var policy = CameraIdlePolicy()
        XCTAssertTrue(policy.hardwareIdle, "A new camera starts downclocked")
        XCTAssertTrue(policy.observe(faceCount: 1, at: 1))
        XCTAssertTrue(policy.updateHardware(at: 1), "A face restores full rate immediately")
        XCTAssertFalse(policy.hardwareIdle)

        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.1))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 1.2))
        XCTAssertTrue(policy.observe(faceCount: 0, at: 1.3))
        XCTAssertTrue(policy.idle)
        XCTAssertFalse(policy.updateHardware(at: 1.3), "Analysis idle alone must not downclock the device")
        XCTAssertFalse(policy.hardwareIdle)

        XCTAssertFalse(policy.updateHardware(at: 1.5), "The 0.6 s window is measured from the last face")
        XCTAssertTrue(policy.updateHardware(at: 1.6))
        XCTAssertTrue(policy.hardwareIdle)
        XCTAssertFalse(policy.updateHardware(at: 1.7), "Already downclocked must not reconfigure")

        XCTAssertTrue(policy.observe(faceCount: 1, at: 1.8))
        XCTAssertTrue(policy.updateHardware(at: 1.8))
        XCTAssertFalse(policy.hardwareIdle)
    }

    func testArbiterNeedsAtLeastOneConsumer() {
        XCTAssertNil(CameraFrameRateArbiter.rate(demands: [], supported: 15...30, constrained: false))
        XCTAssertNil(CameraFrameRateArbiter.rate(demands: [], supported: 15...30, constrained: true))
    }

    func testArbiterSatisfiesEveryMinimumAndRaisesToThePreferredRate() {
        let analysis = CameraFrameRateDemand(minimum: 1 / 0.09)
        let preview = CameraFrameRateDemand.preview
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [analysis, preview], supported: 15...30, constrained: false) ?? 0, 15)
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [preview], supported: 1...60, constrained: false) ?? 0, 15)
        let analysisOnly = CameraFrameRateArbiter.rate(demands: [analysis], supported: 1...60, constrained: false) ?? 0
        XCTAssertEqual(analysisOnly, 1 / 0.09, accuracy: 0.0001)
    }

    func testArbiterFallsBackToMinimumsUnderPowerPressure() {
        let analysis = CameraFrameRateDemand(minimum: 1 / 0.09)
        let preview = CameraFrameRateDemand.preview
        let both = CameraFrameRateArbiter.rate(demands: [analysis, preview], supported: 1...60, constrained: true) ?? 0
        XCTAssertEqual(both, 1 / 0.09, accuracy: 0.0001)
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [preview], supported: 1...60, constrained: true) ?? 0, 10)
    }

    func testArbiterClampsIntoTheSupportedFormatRange() {
        let preview = CameraFrameRateDemand.preview
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [preview], supported: 15...30, constrained: false) ?? 0, 15)
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [preview], supported: 60...120, constrained: false) ?? 0, 60)
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [preview], supported: 24...24, constrained: false) ?? 0, 24)
        XCTAssertEqual(CameraFrameRateArbiter.rate(demands: [CameraFrameRateDemand(minimum: 30)], supported: 15...30, constrained: true) ?? 0, 30)
    }
}
