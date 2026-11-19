import Foundation

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
    var framesPerSecond: Double { idle ? 5 : 10 }
    var analysisInterval: TimeInterval { idle ? 0.2 : 0.09 }

    /// Clamps a requested hardware rate into the active format's supported
    /// range. Idle never drops below 15 fps so the shared picture-in-picture
    /// preview stays fluid; active asks for 30 fps for the lowest detection
    /// latency. Formats that cannot reach a bound stay at their nearest one.
    static func hardwareFramesPerSecond(idle: Bool, supported: ClosedRange<Double>) -> Double {
        let requested = idle ? 15.0 : 30.0
        return min(max(requested, supported.lowerBound), supported.upperBound)
    }

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

/// Tracks whether a viewer-only preview can drop to 15 fps. Preview clients
/// may receive no samples at all while analysis is disabled for a
/// preview-only camera lease, so the idle flag starts active and only
/// throttles after face-free samples prove nobody is in front of the camera.
struct CameraPreviewIdlePolicy {
    static let delay: TimeInterval = 0.6
    static let idleFramesPerSecond: Double = 15

    private(set) var idle = false
    private(set) var lastFaceAt: TimeInterval

    init(now: TimeInterval) { lastFaceAt = now }

    mutating func observe(faceCount: Int, at now: TimeInterval) -> Bool {
        if faceCount > 0 {
            lastFaceAt = now
            guard idle else { return false }
            idle = false
        } else {
            guard !idle, now - lastFaceAt >= Self.delay else { return false }
            idle = true
        }
        return true
    }
}
