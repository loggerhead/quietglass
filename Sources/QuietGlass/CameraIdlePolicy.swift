import Foundation

/// One camera consumer's frame-rate request, modeled after
/// `CADisplayLink.preferredFrameRateRange`: `minimum` is what the consumer
/// needs to stay correct, `preferred` is what it would like when affordable.
struct CameraFrameRateDemand: Equatable {
    var minimum: Double
    var preferred: Double

    init(minimum: Double, preferred: Double? = nil) {
        self.minimum = minimum
        self.preferred = max(minimum, preferred ?? minimum)
    }

    /// The picture-in-picture viewer is fluid at 15 fps and never asks the
    /// shared device for more; under power pressure it can degrade to 10.
    static let preview = CameraFrameRateDemand(minimum: 10, preferred: 15)
}

/// Single authority for the shared capture device rate. Consumers declare
/// ranges instead of setting the device directly, mirroring how Core Animation
/// arbitrates display links: satisfy the highest minimum, raise to the highest
/// preferred only when the system is not under power pressure, then clamp into
/// the active format.
enum CameraFrameRateArbiter {
    static func rate(demands: [CameraFrameRateDemand],
                     supported: ClosedRange<Double>,
                     constrained: Bool) -> Double? {
        guard !demands.isEmpty else { return nil }
        let floor = demands.map(\.minimum).max() ?? supported.lowerBound
        let preferred = demands.map(\.preferred).max() ?? floor
        let target = constrained ? floor : max(floor, preferred)
        return min(max(target, supported.lowerBound), supported.upperBound)
    }
}

/// Camera cadence for nearby-face monitoring. Pure state so the idle/active
/// hysteresis can be verified without a physical capture device.
struct CameraIdlePolicy {
    /// How long the hardware stays at full rate after the last face leaves.
    /// Aggressive on purpose: Vision work already stops with the analysis
    /// cadence, and a face restores full rate on the same sample.
    static let hardwareIdleDelay: TimeInterval = 0.6

    /// Analysis cadence while idle. Hardware runs at its own (higher) rate;
    /// this interval only bounds how often Vision is allowed to run.
    private(set) var idle = true
    private(set) var emptySamples = 0
    /// Whether the capture device itself has been downclocked.
    private(set) var hardwareIdle = true
    private var lastFaceAt: TimeInterval = 0

    /// Analysis rate implied by `analysisInterval`.
    var framesPerSecond: Double { 1 / analysisInterval }
    var analysisInterval: TimeInterval { idle ? 0.2 : 0.09 }

    mutating func setIdle(_ value: Bool) {
        idle = value
        hardwareIdle = value
        emptySamples = 0
    }

    /// Returns true when the analysis cadence changed. A face activates
    /// immediately; three empty samples are required before going back to idle.
    mutating func observe(faceCount: Int, at now: TimeInterval) -> Bool {
        if faceCount > 0 {
            emptySamples = 0
            lastFaceAt = now
            guard idle else { return false }
            idle = false
        } else {
            emptySamples += 1
            guard !idle, emptySamples >= 3 else { return false }
            idle = true
        }
        return true
    }

    /// Returns true when the hardware frame rate should change. A face
    /// restores full rate immediately; the device downclocks only after
    /// `hardwareIdleDelay` without a face so brief re-entries stay cheap.
    mutating func updateHardware(at now: TimeInterval) -> Bool {
        if !idle {
            guard hardwareIdle else { return false }
            hardwareIdle = false
            return true
        }
        guard !hardwareIdle, now - lastFaceAt >= Self.hardwareIdleDelay else { return false }
        hardwareIdle = true
        return true
    }
}
