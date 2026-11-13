import ShieldCore

/// System authorization and a rejected capture session are different states.
/// Retrying a rejected session is explicit, except after newly granted access.
struct RulePermissionState: Equatable {
    var screenGranted = false
    var cameraGranted = false
    var captureRejected = false
    var screenCheckPending = false
    var screenCheckUnavailable = false
    private(set) var screenVerifiedByCaptureAPI = false
    private var lastScreenPreflight: Bool?

    init(screenGranted: Bool = false, cameraGranted: Bool = false, captureRejected: Bool = false) {
        self.screenGranted = screenGranted
        self.cameraGranted = cameraGranted
        self.captureRejected = captureRejected
        lastScreenPreflight = screenGranted
    }

    var captureAllowed: Bool { screenGranted && !captureRejected }
    var needsCaptureRestart: Bool { screenGranted && captureRejected }

    @discardableResult
    mutating func refresh(screen: Bool, camera: Bool, retryRejectedCapture: Bool = false) -> Bool {
        if lastScreenPreflight == true && !screen { screenVerifiedByCaptureAPI = false }
        lastScreenPreflight = screen
        let available = screen || screenVerifiedByCaptureAPI
        let newlyGranted = available && !screenGranted
        let retry = available && (newlyGranted || (captureRejected && retryRejectedCapture))
        screenGranted = available
        cameraGranted = camera
        if retry || !available { captureRejected = false }
        return retry
    }

    mutating func completeScreenCheck(granted: Bool?) {
        screenCheckPending = false
        screenCheckUnavailable = granted == nil
        guard let granted else { return }
        screenVerifiedByCaptureAPI = granted
        screenGranted = granted || lastScreenPreflight == true
        captureRejected = !granted && screenGranted
    }

    mutating func rejectCapture(screenPreflight: Bool) {
        screenCheckUnavailable = false
        screenVerifiedByCaptureAPI = false
        lastScreenPreflight = screenPreflight
        screenGranted = screenPreflight
        captureRejected = true
    }

    func missing(in required: Set<PermissionKind>, motionGranted: Bool) -> Set<PermissionKind> {
        required.filter {
            switch $0 {
            case .screen: return !screenGranted
            case .camera: return !cameraGranted
            case .motion: return !motionGranted
            }
        }
    }
}
