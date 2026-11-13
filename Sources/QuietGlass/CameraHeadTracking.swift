import Combine
import Foundation
import ShieldCore

@MainActor
final class CameraHeadTracking: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "Face your screen to calibrate."
    @Published private(set) var failure: NearbyCameraFailure?
    @Published private(set) var policy = CameraHeadPolicy()
    var comfort = 15.0
    var transition = 18.0
    var onChange: (() -> Void)?
    private(set) var rulePolicies: [UUID: CameraHeadPolicy] = [:]
    private(set) var calibratedRuleIDs = Set<UUID>()
    private var ruleParameters: [UUID: BlurParameters] = [:]
    func configureRules(_ rules: [ProtectionRule]) {
        let values = Dictionary(uniqueKeysWithValues: rules.compactMap { rule -> (UUID, BlurParameters)? in
            guard rule.isEnabled, case .headTurn(.camera) = rule.trigger, case .blur(let blur, _) = rule.action else { return nil }
            return (rule.id, blur)
        })
        rulePolicies = rulePolicies.filter { values[$0.key] != nil }
        for id in values.keys where rulePolicies[id] == nil { rulePolicies[id] = policy }
        calibratedRuleIDs.formIntersection(values.keys)
        ruleParameters = values
    }
    private let access: () async -> Bool
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    private let clock: () -> TimeInterval
    private var camera: NearbyCameraSession?
    private var generation = 0
    private var lastFrame: TimeInterval = 0
    private var acceptedFrame: TimeInterval?
    private var timer: Timer?
    private let usesTimer: Bool
    init(access: @escaping () async -> Bool = NearbyPeople.requestCameraAccess,
         makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = { SharedFaceCamera(completion: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, usesTimer: Bool = true) {
        self.access = access; self.makeCamera = makeCamera; self.clock = clock; self.usesTimer = usesTimer
    }
    func start(deviceID: String, keepCovered: Bool = false) {
        let protected = keepCovered || policy.calibrated || policy.coverage > 0
        stop()
        policy.beginCalibration(keepCovered: protected)
        for id in rulePolicies.keys { rulePolicies[id]?.beginCalibration(keepCovered: protected) }
        running = true; failure = nil; message = "Starting camera…"
        generation += 1
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let allowed = await access()
            guard token == generation, running else { return }
            guard allowed else { fail(.permission); return }
            lastFrame = clock()
            let camera = makeCamera { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token, self.running else { return }
                    switch result {
                    case .success(let sample): self.receive(sample)
                    case .failure(let error): self.fail(error)
                    }
                }
            }
            self.camera = camera
            camera.configureDevice(deviceID); camera.start()
            message = "Look at the screen and hold still for a moment."
            if usesTimer {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            onChange?()
        }
    }
    func recenter() {
        policy.beginCalibration(keepCovered: policy.coverage > 0)
        for id in rulePolicies.keys { let covered = (rulePolicies[id]?.coverage ?? 0) > 0; rulePolicies[id]?.beginCalibration(keepCovered: covered) }
        message = "Look at the screen and hold still for a moment."
        onChange?()
    }
    private func receive(_ sample: NearbyFaceSample) {
        let now = clock()
        guard sample.capturedAt.isFinite, sample.capturedAt <= now, now - sample.capturedAt <= 0.5,
              acceptedFrame.map({ sample.capturedAt > $0 }) ?? true else { return }
        acceptedFrame = sample.capturedAt; lastFrame = now
        policy.observe(sample.faces ?? [], at: sample.capturedAt, comfort: comfort, transition: transition)
        for (id, parameters) in ruleParameters {
            rulePolicies[id]?.observe(sample.faces ?? [], at: sample.capturedAt, comfort: parameters.comfort, transition: parameters.transition)
            if rulePolicies[id]?.calibrated == true { calibratedRuleIDs.insert(id) }
        }
        updateMessage(); onChange?()
    }
    func tick() {
        guard running else { return }
        policy.tick(at: clock())
        for id in rulePolicies.keys { rulePolicies[id]?.tick(at: clock()) }
        if camera != nil, clock() - lastFrame > 4 { fail(.stalled); return }
        updateMessage(); onChange?()
    }
    private func updateMessage() {
        if policy.calibrating { message = policy.hasFace ? "Hold still while your position is calibrated…" : "Keep only your face in view and look at the screen." }
        else if !policy.hasFace { message = policy.coverage > 0 ? "Face unavailable · Screen protected" : "Checking your position…" }
        else { message = policy.coverage > 0 ? "Looking away · Screen protected" : "Camera head tracking is on" }
    }
    private func fail(_ error: NearbyCameraFailure) {
        generation += 1; camera?.stop(); camera = nil
        timer?.invalidate(); timer = nil
        policy.fail(); for id in rulePolicies.keys { rulePolicies[id]?.fail() }; failure = error
        message = QG("%@%@", QG(error.title), QG(policy.coverage > 0 ? " · Screen stays protected" : " · Try again"))
        onChange?()
    }
    func stop() {
        generation += 1; camera?.stop(); camera = nil
        timer?.invalidate(); timer = nil; running = false; failure = nil
        acceptedFrame = nil; policy = CameraHeadPolicy()
        for id in rulePolicies.keys { rulePolicies[id] = CameraHeadPolicy() }
    }
}
