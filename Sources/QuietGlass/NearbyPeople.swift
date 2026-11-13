//  Created by Clinton Imaro on 20/09/2026.

import AVFoundation
import Vision
import Combine
import ShieldCore
import OSLog

enum NearbyResponse: String, CaseIterable, Identifiable {
    case warning, blur
    var id: String { rawValue }
    var title: String { self == .warning ? "Warn me" : "Blur automatically" }
}
enum NearbyRuleCommand {
    case enabled(Bool), detection(NearbyDetection), response(NearbyResponse), delay(TimeInterval), sound(Bool), camera(String)
    case blurNow, pause, resume, tick
}

enum NearbyCameraFailure: Error, Equatable {
    case permission, noCamera, configuration, interrupted, disconnected, stalled, analysis, recognition, ownerAccess
    case screenPermission, escapeUnavailable

    var title: String {
        switch self {
        case .permission: return "Camera access is off"
        case .noCamera: return "No camera available"
        case .interrupted: return "Camera interrupted"
        case .disconnected: return "Camera disconnected"
        case .stalled: return "Camera stopped responding"
        case .analysis: return "Face detection unavailable"
        case .configuration: return "Camera unavailable"
        case .recognition: return "Owner recognition unavailable"
        case .ownerAccess: return "Unlock your saved face to continue"
        case .screenPermission: return "Screen Recording access is off"
        case .escapeUnavailable: return "Escape shortcut is unavailable"
        }
    }
}

enum NearbyCameraStatus: Equatable {
    case off, paused, requesting, starting, watching(Int), unavailable(NearbyCameraFailure)
}

enum NearbyPauseReason: Hashable {
    case systemSleep, displaySleep, inactiveSession, protectionTest, ownerEnrollment, globalPause
}

struct NearbyFaceSample {
    let count: Int
    let capturedAt: TimeInterval
    var vector: [Float]? = nil
    var pose: OwnerPose? = nil
    var bounds: [CGRect] = []
    var faces: [CameraFace]? = nil
    var identities: [CameraIdentity?] = []
}

struct CameraIdentity {
    let vector: [Float]
    let pose: OwnerPose
}

protocol NearbyCameraSession: AnyObject {
    var previewSession: AVCaptureSession? { get }
    func start()
    func stop()
    func configureRecognition(_ enabled: Bool)
    func configureDevice(_ id: String?)
}

extension NearbyCameraSession {
    var previewSession: AVCaptureSession? { nil }
    func configureRecognition(_ enabled: Bool) {}
    func configureDevice(_ id: String?) {}
}

@MainActor
final class NearbyPeople: ObservableObject {
    var onRuleDetections: (([(NearbyDetection, Bool, Bool, Bool)]) -> Void)?
    var onRuleDetection: ((NearbyDetection, Bool, Bool, Bool) -> Void)?
    var onRuleCommand: ((NearbyRuleCommand) -> Void)?
    private struct RuleFaceState {
        var presence = NearbyPresence()
        var attention = NearbyAttentionPolicy()
        var ownerAttention = NearbyAttentionPolicy()
        var verification = OwnerPresence(turnPositive: Bool.random())
        var lastMatchedBounds: CGRect?
        var active = false
        var ownerVerified = false
    }
    private var ruleFaces: [NearbyDetection: RuleFaceState] = [:]
    private var configuredFaceRules: [ProtectionRule] = []
    private enum OwnerNoticeState {
        case checking, matching, unmatched, unreadable, noFace, additionalFaces
    }
    // The switch represents the user's choice, not temporary camera availability.
    @Published private(set) var enabled = false
    @Published private(set) var requesting = false
    @Published private(set) var covered = false
    @Published private(set) var alertActive = false
    @Published private(set) var status: NearbyCameraStatus = .off
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var selectedCameraID: String
    let owner: OwnerRecognition
    var prepareMonitoring: (() -> NearbyCameraFailure?)?
    private let cameraAccess: () async -> Bool
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    private let clock: () -> TimeInterval
    private let usesWatchdog: Bool
    private var worker: NearbyCameraSession?
    private var generation = 0
    private var lastFrame: TimeInterval = 0
    private var lastAcceptedFrame: TimeInterval?
    private var watchdog: Timer?
    private var ownerObservation: AnyCancellable?
    private var ownerRequired = false
    @Published private(set) var ownerPrompt = "Look at the camera"
    @Published private var ownerNoticeState: OwnerNoticeState = .checking
    private var ownerNoticeCandidate: OwnerNoticeState?
    private var ownerNoticeCandidateSince: TimeInterval = 0
    private var pauseReasons: Set<NearbyPauseReason> = []
    private var cameraObservers: [NSObjectProtocol] = []

    init(cameraAccess: @escaping () async -> Bool = NearbyPeople.requestCameraAccess,
         makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = { SharedFaceCamera(completion: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> Date = Date.init,
         usesWatchdog: Bool = true, owner: OwnerRecognition? = nil) {
        self.cameraAccess = cameraAccess
        self.makeCamera = makeCamera
        self.clock = clock
        self.usesWatchdog = usesWatchdog
        self.owner = owner ?? OwnerRecognition()
        selectedCameraID = ""
        ownerObservation = self.owner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshCameras()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    private var currentPlan: ProtectionPlan?
    private var configuredRules: [ProtectionRule] = []
    private var configurationDefaults = ProtectionPreferences()
    var detection: NearbyDetection {
        if case .extraFace(let value) = configuredRules.first?.trigger { return value }; return .facingScreen
    }
    var wantsMonitoring: Bool { configuredRules.contains(where: \.isEnabled) }
    var response: NearbyResponse {
        if case .blur = configuredRules.first?.action { return .blur }; return .warning
    }
    var warningSoundEnabled: Bool {
        switch configuredRules.first?.action {
        case .warnThenBlur(_, let sound), .warnOnly(_, let sound): return sound
        default: return configurationDefaults.defaultWarningSound
        }
    }
    var warningDelay: TimeInterval {
        switch configuredRules.first?.action {
        case .warnThenBlur(let delay, _), .warnOnly(let delay, _): return delay
        default: return configurationDefaults.defaultWarningDelay
        }
    }
    var warningSecondsRemaining: Int? {
        if let value = currentPlan?.warnings.first(where: { warning in configuredRules.contains { $0.id == warning.id } })?.secondsRemaining { return value }
        if currentPlan?.activeRules.contains(where: { active in active.reason == .warningEscalated && configuredRules.contains { $0.id == active.id } }) == true { return 0 }
        return nil
    }
    var pauseSecondsRemaining: Int? {
        guard case .paused(let until) = currentPlan?.state else { return nil }
        return until.map { max(0, Int(ceil($0 - clock()))) }
    }

    func refreshCameras() {
        cameras = CameraSelection.devices().map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func selectCamera(_ id: String) { onRuleCommand?(.camera(id)) }

    nonisolated static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    var canRetry: Bool {
        if case .unavailable = status { return true }
        return false
    }

    var needsCameraPermission: Bool { status == .unavailable(.permission) }
    var needsAttention: Bool { alertActive || canRetry }
    var requiresBlur: Bool { covered || configuredFaceRules.contains { if case .blur = $0.action { return true }; return false } }
    var temporarilyPaused: Bool { if case .paused = currentPlan?.state { return true }; return false }
    var noticeTitle: String {
        if case .unavailable(let failure) = status { return failure.title }
        if ownerRequired { return ownerNoticeTitle }
        return "Additional face detected"
    }
    var noticeDetail: String {
        if covered { return "Blur stays on · Esc to stop" }
        if let remaining = warningSecondsRemaining {
            let minutes = remaining / 60
            let seconds = String(format: "%02d", remaining % 60)
            return QG("Blurs in %@:%@ · Esc to stop", String(minutes), seconds)
        }
        if canRetry { return "Open Settings to retry" }
        return "Look around · Esc to dismiss"
    }

    private var ownerNoticeTitle: String {
        switch ownerNoticeState {
        case .checking: return "Checking your face…"
        case .matching: return alertActive ? ownerPrompt : "Owner verified"
        case .unmatched: return "Owner not verified"
        case .unreadable: return "Face the camera in good light"
        case .noFace: return "No face in view"
        case .additionalFaces: return "Additional face detected"
        }
    }

    var message: String {
        switch status {
        case .off: return "Off"
        case .paused:
            if let seconds = pauseSecondsRemaining { return QG("Paused · Resumes in %ld:%02ld", seconds / 60, seconds % 60) }
            return pauseReasons.contains(.protectionTest) ? "Paused during protection check" : "Paused while your Mac is inactive"
        case .requesting: return ownerRequired ? "Unlocking your saved face…" : "Waiting for camera access…"
        case .starting: return covered ? "Restarting camera · Blur stays on" : "Starting camera…"
        case .unavailable(let failure): return QG("%@%@", QG(failure.title), QG(covered ? " · Blur stays on" : " · Monitoring stopped"))
        case .watching(let count):
            if ownerRequired {
                return ownerNoticeTitle
            }
            if count == 0 { return covered ? "No face in view · Blur stays on" : "No face in view · Detection is limited" }
            if alertActive { return count > 1 ? "Additional face detected" : "Waiting for a steady single face…" }
            return count > 1 ? "Checking nearby head directions…" : "One face in view"
        }
    }

    func setDetection(_ value: NearbyDetection) { onRuleCommand?(.detection(value)) }
    func setResponse(_ value: NearbyResponse) { onRuleCommand?(.response(value)) }
    func setWarningDelay(_ value: TimeInterval) { onRuleCommand?(.delay(value)) }
    func setWarningSoundEnabled(_ value: Bool) { onRuleCommand?(.sound(value)) }
    func setEnabled(_ value: Bool) { onRuleCommand?(.enabled(value)) }
    func retry() { if wantsMonitoring && canRetry { begin() } }
    func restore() { if wantsMonitoring && !enabled && !requesting && !canRetry { begin() } }
    func blurNow() {
        let modes = configuredFaceRules.compactMap { rule -> NearbyDetection? in
            guard currentPlan?.warnings.contains(where: { $0.id == rule.id }) == true,
                  case .extraFace(let mode) = rule.trigger else { return nil }; return mode
        }
        for mode in modes { ruleFaces[mode]?.presence.requireClear(); ruleFaces[mode]?.active = true }
        onRuleCommand?(.blurNow); updateProtection()
    }
    func pauseForFiveMinutes() { onRuleCommand?(.pause) }
    func resumeNow() { onRuleCommand?(.resume) }
    func updatePauseDeadline() { onRuleCommand?(.tick) }
    func checkWarningDeadline() { onRuleCommand?(.tick) }

    func suspend(for reason: NearbyPauseReason) {
        guard pauseReasons.insert(reason).inserted else { return }
        stopSession()
        if wantsMonitoring { status = .paused }
    }

    func resume(after reason: NearbyPauseReason) {
        guard pauseReasons.remove(reason) != nil else { return }
        restore()
    }

    private func begin() {
        guard !temporarilyPaused else { status = .paused; return }
        guard pauseReasons.isEmpty else { status = .paused; return }
        guard !owner.busy, !owner.enrolling else { return }
        if let failure = prepareMonitoring?() {
            failed(failure)
            return
        }
        generation += 1
        let token = generation
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        ownerRequired = configuredFaceRules.contains { $0.guards.contains(.ownerVerification) }
        for mode in ruleFaces.keys {
            let active = ruleFaces[mode]?.active == true || currentPlan?.activeRules.contains { active in
                configuredFaceRules.contains { rule in if case .extraFace(let value) = rule.trigger { return value == mode && rule.id == active.id }; return false }
            } == true
            var state = RuleFaceState()
            if active { state.presence.requireClear(); state.active = true } else { state.presence.interrupt() }
            ruleFaces[mode] = state
        }
        resetOwnerNotice()
        ownerPrompt = ruleFaces[detection]?.verification.challenge.prompt ?? "Look at the camera"
        if ownerRequired {
            enabled = true // Remain armed/turn-off-able if authentication fails.
            alertActive = true
        }
        requesting = true
        status = .requesting
        // Owner mode starts protected, including while authentication is pending.
        updateProtection()
        Task { [weak self, cameraAccess] in
            guard let self, self.generation == token else { return }
            if self.ownerRequired {
                do { try await self.owner.prepareForMonitoring() }
                catch {
                    guard self.generation == token else { return }
                    self.failed(.ownerAccess)
                    return
                }
            }
            let allowed = await cameraAccess()
            guard self.generation == token else { return }
            self.requesting = false
            guard allowed else { self.failed(.permission); return }
            self.enabled = true
            self.lastFrame = self.clock()
            self.lastAcceptedFrame = nil
            self.status = .starting
            self.updateProtection()
            let worker = self.makeCamera { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token, self.enabled else { return }
                    switch result {
                    case .success(let sample): self.received(sample)
                    case .failure(let failure): self.failed(failure)
                    }
                }
            }
            self.worker = worker
            worker.configureDevice(self.selectedCameraID)
            worker.configureRecognition(self.ownerRequired)
            worker.start()
            if self.usesWatchdog {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkCameraHealth() }
                }
                self.watchdog = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func checkCameraHealth() {
        guard enabled, worker != nil, clock() - lastFrame > 4 else { return }
        failed(.stalled)
    }

    private func received(_ sample: NearbyFaceSample) {
        let now = clock()
        guard sample.count >= 0, sample.capturedAt.isFinite, sample.capturedAt >= lastFrame,
              sample.capturedAt <= now, now - sample.capturedAt <= 1 else { return }
        if let lastAcceptedFrame, sample.capturedAt <= lastAcceptedFrame { return }
        if let lastAcceptedFrame, sample.capturedAt - lastAcceptedFrame > 0.6 {
            ownerNoticeCandidate = nil
        }
        lastAcceptedFrame = sample.capturedAt
        lastFrame = sample.capturedAt
        receiveRuleFaces(sample)
    }

    private func receiveRuleFaces(_ sample: NearbyFaceSample) {
        let owners = sample.identities.indices.filter { index in
            guard let identity = sample.identities[index] else { return false }
            return owner.template?.matches(identity.vector) == true && identity.pose.isValid
        }
        let ownerIndex = owners.count == 1 ? owners.first : nil
        for detection in Array(ruleFaces.keys) {
            var state = ruleFaces[detection]!
            let threat = detection == .anyFace ? sample.count > 1 :
                sample.faces.map { state.attention.observe($0, ownerIndex: nil, at: sample.capturedAt) } ?? (sample.count > 1)
            state.active = state.presence.observe(faceCount: sample.count == 0 ? 0 : threat ? 2 : 1, at: sample.capturedAt)
            if ownerRequired {
                let ownerThreat = detection == .anyFace ? sample.count > 1 :
                    sample.faces.map { state.ownerAttention.observe($0, ownerIndex: ownerIndex, at: sample.capturedAt) } ?? (sample.count > 1)
                let identity = ownerIndex.flatMap { sample.identities[$0] }
                let vector = identity?.vector ?? (sample.count == 1 ? sample.vector : nil)
                let pose = identity?.pose ?? (sample.count == 1 ? sample.pose : nil)
                let matches = !ownerThreat && vector.map { owner.template?.matches($0) == true } == true && pose?.isValid == true
                let bounds = ownerIndex.flatMap { sample.bounds.indices.contains($0) ? sample.bounds[$0] : nil } ?? (sample.count == 1 ? sample.bounds.first : nil)
                let lost = sample.count == 1 && (vector == nil || pose?.isValid != true) && OwnerPresence.isContinuousFace(state.lastMatchedBounds, bounds)
                state.ownerVerified = !state.verification.observe(matches: matches, pose: pose,
                    openEyes: owner.template?.openEyes ?? 0.3, at: sample.capturedAt, continuousFaceWithMissingLandmarks: lost)
                if matches { state.lastMatchedBounds = bounds } else if !lost { state.lastMatchedBounds = nil }
                if detection == self.detection {
                    ownerPrompt = state.verification.recoveringLandmarks ? "Face the camera again" : state.verification.challenge.prompt
                    updateOwnerNotice(ownerThreat ? .additionalFaces : sample.count == 0 ? .noFace : vector == nil || pose?.isValid != true ? .unreadable : matches ? .matching : .unmatched, at: sample.capturedAt)
                }
            } else { state.ownerVerified = true }
            ruleFaces[detection] = state
        }
        alertActive = ruleFaces.values.contains { $0.active || (ownerRequired && !$0.ownerVerified) }
        status = .watching(sample.count)
        updateProtection()
    }

    private func resetOwnerNotice() {
        ownerNoticeState = .checking
        ownerNoticeCandidate = nil
    }

    // Stabilize presentation only. Every fresh sample still reaches the owner
    // policy above, so a delayed label cannot defer blur or authorize clearing.
    private func updateOwnerNotice(_ observation: OwnerNoticeState, at time: TimeInterval) {
        guard observation != ownerNoticeState else { ownerNoticeCandidate = nil; return }
        if ownerNoticeCandidate != observation {
            ownerNoticeCandidate = observation
            ownerNoticeCandidateSince = time
        }
        guard time - ownerNoticeCandidateSince >= 0.3 else { return }
        ownerNoticeState = observation
        ownerNoticeCandidate = nil
    }

    private func failed(_ failure: NearbyCameraFailure) {
        generation += 1
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        requesting = false
        for mode in ruleFaces.keys {
            ruleFaces[mode]?.presence.interrupt()
            ruleFaces[mode]?.ownerVerified = false
            ruleFaces[mode]?.verification.interrupt(turnPositive: Bool.random())
        }
        if ownerRequired {
            resetOwnerNotice()
            alertActive = true
            owner.endMonitoring()
        }
        status = .unavailable(failure)
        updateProtection()
    }

    private func updateProtection() {
        let healthy = enabled && !requesting && !canRetry && pauseReasons.isEmpty
        var events: [(NearbyDetection, Bool, Bool, Bool)] = []
        for (mode, state) in ruleFaces {
            let warnOnFailure = configuredFaceRules.contains { rule in
                guard case .extraFace(let value) = rule.trigger, value == mode else { return false }
                if case .warnOnly = rule.action { return true }; if case .warnThenBlur = rule.action { return true }; return false
            }
            events.append((mode, state.active || (warnOnFailure && canRetry), !ownerRequired || (healthy && state.ownerVerified), healthy))
        }
        if let onRuleDetections { onRuleDetections(events) }
        else { for event in events { onRuleDetection?(event.0, event.1, event.2, event.3) } }
    }

    func stop(file: StaticString = #fileID, line: UInt = #line) { onRuleCommand?(.enabled(false)) }

    func shutdown() {
        for observer in cameraObservers { NotificationCenter.default.removeObserver(observer) }
        cameraObservers.removeAll()
        stopSession()
    }

    private func stopSession() {
        generation += 1
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        requesting = false
        enabled = false
        covered = false
        alertActive = false
        owner.endMonitoring()
        ownerRequired = false
        resetOwnerNotice()
        lastAcceptedFrame = nil
        status = .off
        onRuleDetection?(detection, false, true, false)
    }

    func configureRules(_ rules: [ProtectionRule], cameraID: String, startIfNeeded: Bool = true, defaults: ProtectionPreferences = ProtectionPreferences()) {
        configurationDefaults = defaults
        let previouslyWanted = wantsMonitoring
        configuredRules = rules.filter { if case .extraFace = $0.trigger { return true }; return false }
        let enabledRules = configuredRules.filter(\.isEnabled)
        let requested = Set(enabledRules.compactMap { rule -> NearbyDetection? in if case .extraFace(let mode) = rule.trigger { return mode }; return nil })
        let removed = Set(ruleFaces.keys).subtracting(requested)
        for mode in removed { ruleFaces.removeValue(forKey: mode) }
        for mode in requested where ruleFaces[mode] == nil { ruleFaces[mode] = RuleFaceState() }
        configuredFaceRules = enabledRules
        let requiresOwner = enabledRules.contains { $0.guards.contains(.ownerVerification) }
        let restart = previouslyWanted && requiresOwner != ownerRequired
        owner.configureRuleVerification(configuredRules.contains { $0.guards.contains(.ownerVerification) })
        let changedCamera = selectedCameraID != cameraID
        selectedCameraID = cameraID
        owner.configureCamera(cameraID)
        if !wantsMonitoring { stopSession() }
        else if startIfNeeded && (!previouslyWanted || restart || changedCamera) { begin() }
        else { updateProtection() }
        for mode in removed { onRuleDetection?(mode, false, true, false) }
        objectWillChange.send()
    }
    func invalidateRuleOwnerVerification() {
        for mode in ruleFaces.keys {
            ruleFaces[mode]?.ownerVerified = false
            ruleFaces[mode]?.verification.interrupt(turnPositive: Bool.random())
            ruleFaces[mode]?.lastMatchedBounds = nil
        }
        updateProtection()
    }

    func presentRulePlan(_ plan: ProtectionPlan, ruleIDs: Set<UUID>) {
        let next = plan.displays.contains { display in display.hasProtection && display.activeRules.contains { ruleIDs.contains($0.id) } }
        if covered != next { covered = next }
        currentPlan = plan
        if plan.state == .cleared { suspend(for: .globalPause) }
        else if case .paused = plan.state { suspend(for: .globalPause) }
        else if plan.state == .running { resume(after: .globalPause) }
        objectWillChange.send()
    }
}

final class FaceCamera: NSObject, NearbyCameraSession, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let captureQueue = DispatchQueue(label: "local.clinton.QuietGlass.camera", qos: .userInitiated)
    private let queue = FaceCamera.captureQueue
    private let session = AVCaptureSession()
    var previewSession: AVCaptureSession? { session }
    private let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    private var lastScan: TimeInterval = 0
    private var stopped = false
    private var observers: [NSObjectProtocol] = []
    private var analysisFailures = 0
    private var recognition = false
    private var recognizer: OwnerFaceModel?
    private var deviceID: String?

    init(recognition: Bool = false, completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) {
        self.recognition = recognition; self.completion = completion
    }

    func configureRecognition(_ enabled: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            recognition = enabled
            if enabled && recognizer == nil {
                do { recognizer = try OwnerFaceModel() }
                catch { completion(.failure(.recognition)) }
            } else if !enabled { recognizer = nil }
        }
    }
    func configureDevice(_ id: String?) { queue.async { [self] in deviceID = id } }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                if recognition && recognizer == nil {
                    do { recognizer = try OwnerFaceModel() }
                    catch { throw NearbyCameraFailure.recognition }
                }
                guard let device = CameraSelection.device(id: deviceID) else { throw NearbyCameraFailure.noCamera }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NearbyCameraFailure.configuration
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                // Only the on-screen preview is mirrored. Pose directions must
                // always refer to the person's own left and right.
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                limitFrameRate(device)
                observe(AVCaptureSession.runtimeErrorNotification, object: session, failure: .configuration)
                observe(AVCaptureSession.wasInterruptedNotification, object: session, failure: .interrupted)
                observe(AVCaptureDevice.wasDisconnectedNotification, object: device, failure: .disconnected)
                session.startRunning()
                if !session.isRunning { completion(.failure(.configuration)) }
            } catch { completion(.failure(error as? NearbyCameraFailure ?? .configuration)) }
        }
    }

    private func limitFrameRate(_ device: AVCaptureDevice) {
        let fps: Double = 10
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }),
              (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if #available(macOS 15.0, *), device.isAutoVideoFrameRateEnabled { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        if CMTimeCompare(duration, range.maxFrameDuration) <= 0 && CMTimeCompare(duration, range.minFrameDuration) >= 0 {
            device.activeVideoMinFrameDuration = duration
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject, failure: NearbyCameraFailure) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [self] in
                guard !self.stopped else { return }
                self.completion(.failure(failure))
            }
        })
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            session.stopRunning()
            for output in session.outputs { session.removeOutput(output) }
            for input in session.inputs { session.removeInput(input) }
            recognizer = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, now - lastScan >= 0.09, let buffer = sampleBuffer.imageBuffer else { return }
        lastScan = now
        do {
            let sample = try autoreleasepool {
                let faces: [VNFaceObservation]
                if recognition {
                    faces = try OwnerFaceDetector.observations(in: buffer)
                } else {
                    let request = VNDetectFaceRectanglesRequest()
                    request.revision = VNDetectFaceRectanglesRequestRevision3
                    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
                    faces = (request.results ?? []).filter { $0.confidence >= 0.6 }
                }
                var sample = NearbyFaceSample(count: faces.count, capturedAt: now, bounds: faces.map(\.boundingBox))
                sample.faces = faces.map { CameraFace(bounds: $0.boundingBox, yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue) }
                if recognition {
                    guard let recognizer else { throw OwnerModelError.unavailable }
                    sample.identities = try faces.map { face in
                        guard let features = try recognizer.features(buffer: buffer, face: face) else { return nil }
                        return CameraIdentity(vector: features.vector, pose: features.pose)
                    }
                    if faces.count == 1, let identity = sample.identities.first ?? nil {
                        sample.vector = identity.vector; sample.pose = identity.pose
                    }
                }
                return sample
            }
            analysisFailures = 0
            completion(.success(sample))
        } catch {
            analysisFailures += 1
            if analysisFailures >= 3 { completion(.failure(.analysis)) }
        }
    }
}
