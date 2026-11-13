// Clinton Imaro was here 20/09/2026.

import AppKit
import AVFoundation
import Carbon
import Combine
import CoreMotion
import ScreenCaptureKit
import ShieldCore
import simd

@MainActor
final class AppModel: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    @Published private(set) var protectionCoordinator: ProtectionCoordinator?
    private let ruleExecutor: ScreenBlurExecutor
    private let screenAccess: () -> Bool
    private let cameraPermission: () -> Bool
    private var syncingRules = false
    private var shuttingDown = false
    @Published private(set) var rulePermissions = RulePermissionState()
    private let startsPermissionSensors: Bool
    private let screenPermissionVerifier = ScreenPermissionVerifier()
    private let previewRuleID = UUID()
    private let ruleRegionSelector = AreaSelectionController()
    private let ruleRegionMarker = RuleRegionMarker()
    var presentRuleRegionSelection: ((@escaping (SelectedDisplayRegion) -> Void) -> Void)?
    var requestRulePermission: ((PermissionKind) -> Void)?
    private var requestedRulePermissions: Set<PermissionKind> = []
    private var ruleObservation: AnyCancellable?
    private var nearbyRuleAdapter: NearbyRuleAdapter?
    @Published private(set) var trackingSource: HeadTrackingSource
    let cameraTracking: CameraHeadTracking
    private var cameraPauses: Set<NearbyPauseReason> = []
    private var protectCameraOnResume = false
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var calibrated = false
    @Published private(set) var coverage = 0.0
    @Published private(set) var offset = HeadOffset(yaw: 0, pitch: 0)
    @Published private(set) var status = "Ready when you are"
    @Published private(set) var detail = "Connect your AirPods to this Mac, then start head tracking."
    @Published private(set) var captureNotice: String?
    var screenPermission: Bool { rulePermissions.screenGranted }
    var screenCaptureNeedsRestart: Bool { rulePermissions.needsCaptureRestart }
    @Published private(set) var restarting = false
    @Published private(set) var previewing = false
    @Published private(set) var shortcutNotice: String?
    @Published var recordingRuleShortcut = false {
        didSet {
            if recordingRuleShortcut { shortcuts.suspendRuleRecording() }
            else { protectionCoordinator?.send(.tick) }
        }
    }
    @Published var demoMode: Bool {
        didSet {
            saveAppearance("includeBlurInCaptures", demoMode)
            ruleExecutor.includeInCaptures = demoMode
        }
    }
    @Published var comfort: Double { didSet { save("comfort", comfort); refreshResponse() } }
    @Published var transition: Double { didSet { save("transition", transition); refreshResponse() } }
    @Published var blur: Double { didSet { save("blur", blur) } }
    var areaShortcutLabel: String {
        let rule = protectionCoordinator?.document.rules.first { rule in
            if case .manual = rule.trigger, case .region(let ref, _, _) = rule.scope { return ref.bundleID == "$selection" }; return false
        }
        if case .manual(let shortcut) = rule?.trigger { return shortcut?.label ?? "" }; return ""
    }
    func beginRuleRegionSelection(action: @escaping () -> Void) -> ShortcutBinding? {
        let configured = protectionCoordinator?.document.preferences.regionSelectionShortcut ?? protectionCoordinator?.document.rules.compactMap { rule -> ShortcutBinding? in
            guard case .manual(let shortcut) = rule.trigger, case .region(let ref, _, _) = rule.scope,
                  ref.bundleID == "$selection" else { return nil }
            return shortcut
        }.first
        return shortcuts.beginRegionSelection(configured.map { [$0] } ?? [], action: action)
    }
    func chooseRuleRegion(selected: @escaping (SelectedDisplayRegion) -> Void) {
        let complete: (SelectedDisplayRegion) -> Void = { [weak self] value in self?.ruleRegionMarker.show(value); selected(value) }
        if let presentRuleRegionSelection { presentRuleRegionSelection(complete); return }
        let displays = NSScreen.screens.compactMap { screen -> ProtectionDisplay? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ProtectionDisplay(id: id, frame: screen.frame)
        }
        ruleRegionSelector.show(displays: displays, selected: complete)
    }
    func showRuleRegionMarker(_ selection: SelectedDisplayRegion?) { ruleRegionMarker.show(selection) }
    func endRuleRegionSelection() { shortcuts.endRegionSelection(); ruleRegionSelector.close() }
    @Published private(set) var learning = false
    @Published private(set) var learningProgress = 0.0
    @Published private(set) var suggestedComfort: Double?
    @Published private(set) var learningNotice: String?
    @Published private(set) var headSetupActive = false

    @Published var perDisplayTracking = false {
        didSet { displayTracking.invalidate(); displayCalibrationIDs = []; clearOverlay(); updateShield() }
    }
    @Published private(set) var displayCalibrationIDs = Set<UInt32>()
    @Published private(set) var displayCalibrationNotice: String?
    private var displayTracking = DisplayHeadTracking()
    private var ruleHeadResponses: [UUID: ShieldResponse] = [:]
    private var ruleDisplayTracking: [UUID: DisplayHeadTracking] = [:]
    private var ruleDisplayCenters: [UUID: [UInt32: simd_quatd]] = [:]
    private var displayCalibrationTask: Task<Void, Never>?
    private var displayLayout: [UInt32: CGRect] = [:]

    let privacy = PrivacyController()
    let nearby: NearbyPeople
    let protectionCheck = ProtectionCheck()
    let loginPreference = LoginPreference()
    let updates: AppUpdates
    private var maintenanceObservations: [AnyCancellable] = []
    private var protectionCheckObservation: AnyCancellable?
    private var nearbyObservation: AnyCancellable?
    var onOpenPrivacySettings: (() -> Void)?
    var onOpenNearbySettings: (() -> Void)?
    var onOpenProtection: (() -> Void)?
    var onOpenRules: (() -> Void)?
    var onRequestHeadSetup: (() -> Void)?
    var onCancelHeadSetup: (() -> Void)?

    private lazy var motion = CMHeadphoneMotionManager()
    private var motionHasStarted = false
    private var motionLifecyclePaused = false
    private var motionRunGeneration = 0
    private var motionAwaitingSample = false
    private let shortcuts = GlobalShortcuts()
    private var center: simd_quatd?
    private var latest: simd_quatd?
    private var sourceLocation: CMDeviceMotion.SensorLocation?
    private var lastSample: TimeInterval = 0
    private var lastPublished: TimeInterval = 0
    private var everCalibrated = false
    private var dismissedForLoss = false
    private var pendingCalibration = false
    private var timer: Timer?
    private var previewEnd: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var privacyObservation: AnyCancellable?
    private var calibration = AdaptiveCalibration()
    private var learningStarted: TimeInterval = 0
    private var setupSnapshot: HeadSetupSnapshot?
    private var motionReferenceGeneration = 0

    private struct HeadSetupSnapshot {
        let enabled: Bool
        let comfort: Double
        let center: simd_quatd?
        let source: CMDeviceMotion.SensorLocation?
        let generation: Int
        let calibrated: Bool
        let everCalibrated: Bool
        let dismissedForLoss: Bool
        let ruleResponses: [UUID: ShieldResponse]
    }

    override convenience init() {
        self.init(preferences: .standard)
    }
    init(preferences: UserDefaults, executor: ProtectionPlanExecuting? = nil,
         nearby suppliedNearby: NearbyPeople? = nil, cameraTracking suppliedCamera: CameraHeadTracking? = nil, screenAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         cameraPermission: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, runsRuleTimer: Bool = true, startsEventSources: Bool = true) {
        updates = AppUpdates(preferences: preferences)
        startsPermissionSensors = startsEventSources
        self.screenAccess = screenAccess
        self.cameraPermission = cameraPermission
        self.nearby = suppliedNearby ?? NearbyPeople()
        self.cameraTracking = suppliedCamera ?? CameraHeadTracking()
        rulePermissions = RulePermissionState(screenGranted: screenAccess(), cameraGranted: cameraPermission())
        let renderer = ScreenBlurExecutor()
        ruleExecutor = renderer
        var migrationError: Error?
        let coordinator: ProtectionCoordinator?
        do { coordinator = try ProtectionCoordinator(store: ProtectionStore(storage: preferences), executor: executor ?? renderer, clock: clock, runsTimer: runsRuleTimer) }
        catch { coordinator = nil; migrationError = error }
        protectionCoordinator = coordinator
        let initial = coordinator?.document.preferences.defaultBlur ?? BlurParameters()
        trackingSource = .airPods; demoMode = false
        comfort = initial.comfort; transition = initial.transition; blur = initial.radius
        super.init()
        if startsEventSources { verifyScreenPermission() }
        updates.useProtectionPreferences(read: { [weak self] in self?.presentationPreference($0) },
                                         write: { [weak self] in self?.setPresentationPreference($0, $1) })
        if coordinator == nil { nearby.configureRules([], cameraID: "") }
        if migrationError != nil { captureNotice = "Rules could not be loaded. Your saved preferences are unchanged. Restart to retry migration." }
        cameraTracking.onChange = { [weak self] in self?.receiveCameraTracking() }
        protectionCheck.onBegin = { [weak self] in self?.nearby.suspend(for: .protectionTest); self?.pauseCamera(for: .protectionTest) }
        protectionCheck.onEnd = { [weak self] in self?.nearby.resume(after: .protectionTest); self?.resumeCamera(after: .protectionTest) }
        protectionCheck.onDemoCoverage = { [weak self] in self?.privacy.setTestCovered($0) }
        protectionCheck.demoAvailable = { [weak self] in self?.privacy.captureUnavailable == false }
        protectionCheckObservation = protectionCheck.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
        maintenanceObservations = [
            loginPreference.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            updates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
        nearby.prepareMonitoring = { [weak self] in
            guard let self else { return .escapeUnavailable }
            if self.nearby.response == .blur, !self.screenPermission { return .screenPermission }
            guard self.shortcuts.armEscape(true) else {
                self.shortcutNotice = "Escape is unavailable. Nearby people could not start."
                return .escapeUnavailable
            }
            return nil
        }
        nearbyObservation = nearby.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
            if self?.protectionCoordinator == nil {
                self?.refreshEscape()
                self?.updateShield()
            }
        }
        refreshResponse()
        shortcuts.onRecenter = { [weak self] in self?.recenter() }
        shortcuts.onEscape = { [weak self] in
            guard let self else { return }
            self.ruleRegionSelector.close()
            if self.recordingRuleShortcut { self.recordingRuleShortcut = false }
            if self.headSetupActive { self.onCancelHeadSetup?() } else { self.dismissShield() }
        }
        shortcuts.onRule = { [weak self] shortcut, pressed in self?.handleRuleShortcut(shortcut, pressed: pressed) }
        privacyObservation = privacy.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.privacy.ruleSources?.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRulePermissions(retryRejectedCapture: true); self?.verifyScreenPermission(); self?.loginPreference.refresh(); self?.updates.checkIfDue() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recordingRuleShortcut = false }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        })
        let nearbyLifecycle: [(Notification.Name, Notification.Name, NearbyPauseReason)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)
        ]
        for (pause, resume, reason) in nearbyLifecycle {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.suspend(for: reason); self?.pauseCamera(for: reason) }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.resume(after: reason); self?.resumeCamera(after: reason) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nearby.resume(after: .systemSleep)
                self.resumeCamera(after: .systemSleep)
                self.protectionCoordinator?.wake()
                guard self.enabled else { return }
                self.detail = "Look at your screen and recenter after waking your Mac."
                self.beginMotionIfAvailable()
                self.updateShield()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        if let coordinator {
            coordinator.warnings.visible = false
            let sources = RuleEventSources(coordinator: coordinator)
            privacy.attachRules(sources)
            if startsEventSources {
                coordinator.refreshContext = { [weak self, weak sources] in
                    guard let self else { return [] }
                    self.refreshRulePermissions()
                    return (sources?.contextEvents() ?? []) + self.ruleShieldEvents(resuming: true)
                }
            }
            sources.onRetryCapture = { [weak renderer] in renderer?.retryCapture() }
            coordinator.prepareEscape = { [weak self] in
                guard let self, let coordinator = self.protectionCoordinator else { return false }
                let document = coordinator.document
                if !self.recordingRuleShortcut && !self.shortcuts.configureRules(ShortcutRegistry(rules: document.rules, recenter: document.preferences.recenterShortcut),
                    recenter: document.preferences.recenterShortcut, activeManualRules: coordinator.activeManualRuleIDs) {
                    self.shortcutNotice = "The peek shortcut is in use. Record a different one."
                }
                let needsEscape = coordinator.requiresEscape
                let available = self.shortcuts.armEscape(needsEscape)
                return needsEscape && available
            }
            coordinator.prepareRuleBindings = { [weak self] document in
                guard let self, let coordinator = self.protectionCoordinator else { return false }
                let registry = ShortcutRegistry(rules: document.rules, recenter: document.preferences.recenterShortcut)
                let previous = ShortcutRegistry(rules: coordinator.document.rules, recenter: coordinator.document.preferences.recenterShortcut)
                let changedPeekIDs = Set(registry.bindings.filter { binding in
                    guard binding.operation == .peek else { return false }
                    return !previous.bindings.contains { $0.ruleID == binding.ruleID && $0.operation == .peek &&
                        $0.binding.keyCode == binding.binding.keyCode && $0.binding.modifiers == binding.binding.modifiers }
                }.map(\.ruleID))
                return self.shortcuts.configureRules(registry, recenter: document.preferences.recenterShortcut,
                    activeManualRules: coordinator.activeManualRuleIDs.union(changedPeekIDs))
            }
            coordinator.onRulesChanged = { [weak self] _ in self?.syncRuleConfiguration() }
            coordinator.onPlanChanged = { [weak self] plan in self?.receiveRulePlan(plan) }
            renderer.onText = { [weak coordinator] id, regions in coordinator?.send(.detectedText(id, regions: regions)) }
            renderer.onFailure = { [weak self] error in
                self?.privacy.ruleCaptureFailed(error)
                let failure = error as NSError
                if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
                    self?.recordCapturePermissionFailure()
                }
            }
            renderer.onReady = { [weak self] in
                guard let self else { return }
                if self.rulePermissions.captureRejected {
                    self.rulePermissions.captureRejected = false
                    self.protectionCoordinator?.send(.permission(.screen, granted: self.screenPermission))
                }
                self.privacy.ruleCaptureReady()
            }
            renderer.onTextFailure = { [weak self] _ in self?.privacy.ruleTextFailed() }
            let faceAdapter = NearbyRuleAdapter(nearby: nearby, coordinator: coordinator, cameraPermission: cameraPermission)
            faceAdapter.onError = { [weak self] _ in self?.captureNotice = "Protection rules could not be saved. Your previous rules are still in use." }
            nearbyRuleAdapter = faceAdapter
            coordinator.onRulesEnabled = { [weak self] rules in self?.guideRulePermissions(rules, force: true) }
            coordinator.onBlurPermissionNeeded = { [weak self, weak coordinator] rule in
                guard let self, let coordinator else { return }
                var blurRule = rule; blurRule.action = .blur(coordinator.document.preferences.defaultBlur, peek: nil)
                self.guideRulePermissions([blurRule], force: true)
            }
            syncRuleConfiguration()
            ruleObservation = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        refreshDisplays()
        if startsEventSources {
            privacy.start()
        }
    }

    var fullCoverAngle: Int { Int(comfort + transition) }
    var cameraPermissionGranted: Bool { rulePermissions.cameraGranted }
    func permissionGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screen: return screenPermission
        case .camera: return cameraPermissionGranted
        case .motion:
            let value = CMHeadphoneMotionManager.authorizationStatus()
            return value == .authorized
        }
    }
    func missingPermissions(for rule: ProtectionRule) -> Set<PermissionKind> {
        var missing = rulePermissions.missing(in: rule.requiredPermissions, motionGranted: permissionGranted(.motion))
        if rulePermissions.screenCheckPending || rulePermissions.screenCheckUnavailable { missing.remove(.screen) }
        return missing
    }
    func guideRulePermissions(_ rules: [ProtectionRule], force: Bool = false) {
        refreshRulePermissions()
        let missing = rules.reduce(into: Set<PermissionKind>()) { $0.formUnion(missingPermissions(for: $1)) }
        for kind in [PermissionKind.screen, .camera, .motion] where missing.contains(kind) && (force || !requestedRulePermissions.contains(kind)) {
            requestedRulePermissions.insert(kind)
            if let requestRulePermission { requestRulePermission(kind); continue }
            switch kind {
            case .screen: requestScreenPermission()
            case .camera: requestCameraPermission()
            case .motion: openMotionSettings()
            }
        }
    }
    func requestCameraPermission() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await NearbyPeople.requestCameraAccess()
            if !granted { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
            refreshRulePermissions()
            if granted { syncRuleConfiguration(); if nearby.canRetry { nearby.retry() }; updateRuleShield() }
            objectWillChange.send()
        }
    }
    var canRecenter: Bool { trackingSource == .camera ? enabled && cameraTracking.failure == nil && cameraPauses.isEmpty : enabled && connected && latest != nil && ProcessInfo.processInfo.systemUptime - lastSample < 1.5 }
    var hasCompletedHeadSetup: Bool { appearanceValues()["headSetupCompleted.v1"] as? Bool ?? false }
    var screenAccessPreviouslyGranted: Bool { appearanceValues()["screenAccessPreviouslyGranted"] as? Bool ?? false }
    var screenAccessAction: String { screenAccessPreviouslyGranted ? "Restore screen access" : "Allow screen access" }

    var connectedDisplays: [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen.localizedName)
        }
    }

    func calibrateDisplay(_ id: UInt32) {
        displayCalibrationTask?.cancel()
        displayCalibrationTask = Task { [weak self] in
            for second in stride(from: 3, through: 1, by: -1) {
                guard let self else { return }
                self.displayCalibrationNotice = QG("Face the selected display · %ld", second)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            guard let self, self.perDisplayTracking, self.canRecenter, let latest = self.latest,
                  self.connectedDisplays.contains(where: { $0.id == id }) else {
                self?.displayCalibrationNotice = "Motion unavailable. Connect your AirPods and try again."
                return
            }
            if !self.calibrated { self.recenter() }
            self.displayTracking.calibrate(id, at: latest)
            self.displayCalibrationIDs = Set(self.displayTracking.centers.keys)
            self.displayCalibrationNotice = "Display centered. Repeat for your other displays."
            self.updateShield()
        }
    }

    private func refreshDisplays() {
        let layout = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, CGRect)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen.frame)
        })
        if !displayLayout.isEmpty, displayLayout != layout { invalidateDisplayCalibration() }
        displayLayout = layout
        privacy.ruleSources?.refresh()
    }

    private func invalidateDisplayCalibration() {
        displayCalibrationTask?.cancel(); displayCalibrationTask = nil
        displayTracking.invalidate()
        displayCalibrationIDs = []
        if perDisplayTracking { displayCalibrationNotice = "Head motion changed. Center each display again." }
    }

    var currentProfile: PrivacyProfile? {
        if privacy.focusEnabled { return .focus }
        return PrivacyProfile.allCases.first { $0 != .focus && $0.settings.comfort == comfort && $0.settings.transition == transition && $0.settings.blur == blur }
    }

    var notchClearsProtection: Bool {
        previewing || privacy.fullScreen || privacy.focusEnabled || nearby.wantsMonitoring
    }

    var nearbyBlurUnavailable: Bool { (nearby.enabled || nearby.requesting || nearby.covered) && nearby.requiresBlur && privacy.captureUnavailable }
    var nearbyNeedsAttention: Bool { nearby.needsAttention || nearbyBlurUnavailable || nearby.temporarilyPaused || protectionCheck.demoSeconds != nil || protectionCheck.demoBlurred }
    var nearbyNoticeTitle: String {
        if protectionCheck.demoSeconds != nil || protectionCheck.demoBlurred { return "Protection test" }
        if nearby.temporarilyPaused { return "Nearby people paused" }
        return nearbyBlurUnavailable ? "Privacy blur unavailable" : nearby.noticeTitle
    }
    var nearbyNoticeDetail: String {
        if let seconds = protectionCheck.demoSeconds { return QG("Test blur starts in %ld seconds", seconds) }
        if protectionCheck.demoBlurred {
            return privacy.captureUnavailable ? "Test blur unavailable · Check Screen Recording" : "Test blur clears automatically · Esc to stop"
        }
        if let seconds = nearby.pauseSecondsRemaining {
            return QG("Resumes in %ld:%02ld", seconds / 60, seconds % 60)
        }
        if nearbyBlurUnavailable { return "Open Settings to restore it" }
        if nearby.covered && !privacy.ready { return "Preparing blur · Esc to clear" }
        return nearby.noticeDetail
    }

    func blurNearbyNow() {
        guard screenPermission else { requestScreenPermission(); return }
        nearby.blurNow()
    }

    func applyProfile(_ profile: PrivacyProfile) {
        comfort = profile.settings.comfort
        transition = profile.settings.transition
        blur = profile.settings.blur
        setFocus(profile == .focus)
        updateShield()
    }

    func setFocus(_ value: Bool) {
        privacy.setFocus(value)
    }

    func setNearbyPeople(_ value: Bool) {
        if value, nearby.owner.busy || nearby.owner.enrolling { return }
        nearby.setEnabled(value)
        if value, nearby.status == .unavailable(.screenPermission) { requestScreenPermission() }
    }

    func setNearbyResponse(_ value: NearbyResponse) {
        if value == .blur, nearby.enabled || nearby.requesting, !screenPermission { requestScreenPermission(); return }
        nearby.setResponse(value)
    }

    func retryNearbyPeople() {
        if nearby.response == .blur, !screenPermission { requestScreenPermission(); return }
        guard shortcuts.armEscape(true) else { shortcutNotice = "Escape is unavailable. Nearby people could not start."; return }
        nearby.retry()
    }

    func retryNearbyBlur() {
        guard screenPermission else { requestScreenPermission(); return }
        privacy.start()
    }

    func selectTrackingCamera(_ id: String) {
        let resume = enabled && trackingSource == .camera
        if resume { protectCameraOnResume = cameraTracking.policy.calibrated || cameraTracking.policy.coverage > 0; cameraTracking.stop() }
        nearby.selectCamera(id)
        if resume { startCameraTracking() }
    }

    func retryCameraTracking() { startCameraTracking() }

    func calibrateHeadSource(_ source: HeadTrackingSource) {
        switch source {
        case .camera:
            if cameraTracking.running && cameraTracking.failure == nil { cameraTracking.recenter() }
            else { startCameraTracking() }
        case .airPods:
            if canRecenter && trackingSource == .airPods { recenter() }
            else { onRequestHeadSetup?() }
        }
    }

    private func startCameraTracking() {
        let wantsCamera = protectionCoordinator?.document.rules.contains { rule in
            if case .headTurn(.camera) = rule.trigger { return rule.isEnabled }; return false
        } ?? (enabled && trackingSource == .camera)
        guard wantsCamera, cameraPauses.isEmpty, !cameraTracking.running || cameraTracking.failure != nil else { return }
        refreshResponse()
        cameraTracking.start(deviceID: nearby.selectedCameraID, keepCovered: protectCameraOnResume)
        protectCameraOnResume = false
        receiveCameraTracking()
    }

    private func receiveCameraTracking() {
        if protectionCoordinator != nil, trackingSource != .camera {
            objectWillChange.send(); updateRuleShield(); return
        }
        guard enabled, trackingSource == .camera else { return }
        connected = cameraTracking.policy.hasFace
        calibrated = cameraTracking.policy.calibrated
        if calibrated { everCalibrated = true }
        offset = cameraTracking.policy.offset
        detail = cameraTracking.message
        objectWillChange.send()
        updateShield()
    }

    func pauseCamera(for reason: NearbyPauseReason) {
        if reason == .systemSleep || reason == .displaySleep || reason == .inactiveSession { protectionCoordinator?.suspend() }
        guard cameraPauses.insert(reason).inserted, cameraTracking.running else { return }
        protectCameraOnResume = protectCameraOnResume || cameraTracking.policy.calibrated || cameraTracking.policy.coverage > 0
        cameraTracking.stop(); updateRuleShield()
        status = "Camera head tracking paused"
    }

    func resumeCamera(after reason: NearbyPauseReason) {
        guard cameraPauses.remove(reason) != nil else { return }
        if !cameraPauses.contains(.systemSleep), !cameraPauses.contains(.displaySleep), !cameraPauses.contains(.inactiveSession) { protectionCoordinator?.wake() }
        startCameraTracking()
    }

    private var notchSuspendedRuleIDs: Set<UUID> = []
    var headRulesEnabled: Bool {
        protectionCoordinator?.document.rules.contains { rule in if case .headTurn = rule.trigger { return rule.isEnabled }; return false } == true
    }
    var currentAutomaticRuleIDs: Set<UUID> {
        guard let coordinator = protectionCoordinator else { return [] }
        let active = Set(coordinator.plan.activeRules.map(\.id))
        return Set(coordinator.document.rules.filter { rule in
            guard rule.isEnabled, active.contains(rule.id) else { return false }
            if case .manual = rule.trigger { return false }; return true
        }.map(\.id))
    }
    var automaticDetectionEnabled: Bool { !currentAutomaticRuleIDs.isEmpty }
    func setAutomaticDetection(_ active: Bool) {
        guard let coordinator = protectionCoordinator else { return }
        let targets = active ? notchSuspendedRuleIDs : currentAutomaticRuleIDs
        guard !targets.isEmpty else {
            // Clearing protection keeps setups enabled but suppresses their
            // responses, so nothing is "active" yet. Turning detection back on
            // should re-arm them instead of reporting that none exist.
            let hasEnabledAutomatic = coordinator.document.rules.contains { rule in
                guard rule.isEnabled else { return false }
                if case .manual = rule.trigger { return false }; return true
            }
            if active, hasEnabledAutomatic, (coordinator.plan.state == .cleared || coordinator.plan.state == .running) {
                coordinator.resume(); return
            }
            captureNotice = "No automatic setup is currently active or available to resume. Review enabled setups and their conditions in Auto & shortcuts."
            onOpenRules?(); return
        }
        var rules = coordinator.document.rules
        for index in rules.indices where targets.contains(rules[index].id) {
            if case .manual = rules[index].trigger { continue }
            rules[index].isEnabled = active
        }
        do {
            try coordinator.saveRules(rules)
            if active { notchSuspendedRuleIDs.subtract(targets) } else { notchSuspendedRuleIDs.formUnion(targets) }
        } catch { captureNotice = "Protection rules could not be saved. Your previous rules are still in use." }
    }

    func start() {
        guard protectionCoordinator != nil else { return }
        guard !enabled else { return }
        if trackingSource == .camera {
            guard screenPermission else { requestScreenPermission(); return }
            guard shortcuts.armEscape(true) else { shortcutNotice = "Escape is unavailable. Camera tracking could not start."; return }
            enabled = true; dismissedForLoss = false
            setHeadRulesEnabled(true)
            startCameraTracking(); return
        }
        if !headSetupActive, !hasCompletedHeadSetup, let onRequestHeadSetup {
            onRequestHeadSetup()
            return
        }
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        guard auth != .denied && auth != .restricted else {
            status = "Motion permission needed"
            detail = "Allow QuietGlass in System Settings → Privacy & Security → Motion & Fitness."
            return
        }
        enabled = true
        setHeadRulesEnabled(true)
        motionHasStarted = true; motionLifecyclePaused = false
        motion.delegate = self
        status = "Connecting to AirPods"
        detail = "Wear at least one AirPod, look at the screen, then click Center my gaze."
        motion.startConnectionStatusUpdates()
        beginMotionIfAvailable()
    }

    func stop() {
        let wasUsingMotion = motionHasStarted
        motionHasStarted = false; motionLifecyclePaused = false; motionRunGeneration += 1
        cancelLearning()
        invalidateDisplayCalibration()
        enabled = false
        if !shuttingDown { setHeadRulesEnabled(false) }
        protectCameraOnResume = false
        cameraTracking.stop()
        if wasUsingMotion { motion.stopDeviceMotionUpdates(); motion.stopConnectionStatusUpdates() }
        center = nil
        latest = nil
        sourceLocation = nil
        calibrated = false
        connected = false
        everCalibrated = false
        dismissedForLoss = false
        pendingCalibration = false
        ruleHeadResponses = [:]
        stopPreview()
        clearOverlay()
        status = "Paused"
        detail = "Your screen stays clear while head tracking is paused."
    }

    private func beginMotionIfAvailable() {
        guard trackingSource == .airPods, enabled, !motionLifecyclePaused,
              !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        motionReferenceGeneration += 1
        invalidateDisplayCalibration()
        motionRunGeneration += 1
        let run = motionRunGeneration
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            guard let self, self.enabled, !self.motionLifecyclePaused, self.motionRunGeneration == run else { return }
            if let error {
                self.detail = error.localizedDescription
                return
            }
            if let sample { self.receive(sample) }
        }
    }

    private func receive(_ sample: CMDeviceMotion) {
        guard enabled, trackingSource == .airPods else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let q = sample.attitude.quaternion
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite else { return }
        if let previous = sourceLocation, previous != sample.sensorLocation {
            motionReferenceGeneration += 1
            invalidateDisplayCalibration()
            cancelLearning(message: "The active AirPod changed. Recenter and try again.")
            center = nil
            calibrated = false
            detail = "The active AirPod changed. Face your screen and recenter."
        }
        sourceLocation = sample.sensorLocation
        latest = simd_normalize(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w))
        lastSample = now; motionAwaitingSample = false
        if !connected { connected = true }
        if pendingCalibration { recenter() }
        if let center, let latest, now - lastPublished > 1.0 / 30 {
            lastPublished = now
            offset = HeadOffset.between(center: center, current: latest)
            if learning { calibration.record(angle: offset.angle) }
            updateShield()
        } else if center == nil {
            updateShield()
            if !everCalibrated { status = "Center your gaze" }
        }
    }

    func recenter() {
        cancelLearning()
        if !enabled { start() }
        guard enabled else { return }
        if trackingSource == .camera {
            if cameraTracking.failure != nil { startCameraTracking() } else { cameraTracking.recenter() }
            return
        }
        guard connected, ProcessInfo.processInfo.systemUptime - lastSample < 1.5, let latest else {
            pendingCalibration = true
            detail = "Waiting for motion. Keep your AirPods connected and face the screen."
            return
        }
        center = latest
        if perDisplayTracking, let facing = displayTracking.facing { displayTracking.calibrate(facing, at: latest) }
        calibrated = true
        everCalibrated = true
        pendingCalibration = false
        dismissedForLoss = false
        offset = HeadOffset(yaw: 0, pitch: 0)
        ruleHeadResponses = [:]
        stopPreview()
        clearOverlay()
        status = "Watching your head motion"
        detail = QG("Small movements stay clear. Turn past %ld° to cover the screen.", Int(comfort))
    }

    func dismissShield() {
        protectionCheck.stopDemonstration()
        // Clearing is a temporary runtime action. Suspend sensors without
        // rewriting rule switches so automatic setups stay enabled and can be
        // resumed instead of being silently turned off.
        nearby.suspend(for: .globalPause)
        if trackingSource == .camera { pauseCamera(for: .globalPause) }
        cancelLearning()
        stopPreview()
        for id in ruleHeadResponses.keys { ruleHeadResponses[id]?.dismiss() }
        displayTracking.dismiss()
        dismissedForLoss = true
        privacy.dismissAll()
        clearOverlay()
        if let coordinator = protectionCoordinator { receiveRulePlan(coordinator.plan); return }
        status = enabled ? "Shield dismissed" : "Paused"
        detail = "Face your screen to rearm, or use Center my gaze."
    }

    private func updateShield() { updateRuleShield() }

    private func clearOverlay() {
        guard let coordinator = protectionCoordinator else { return }
        coordinator.send(coordinator.document.rules.compactMap { rule -> ProtectionEvent? in
            guard case .headTurn = rule.trigger else { return nil }
            return .headRuleCoverage(rule.id, coverage: 0, displays: [:], calibrated: false)
        })
    }

    private func refreshEscape() {
        _ = shortcuts.armEscape(protectionCoordinator?.requiresEscape == true)
    }

    func toggleInstantShield() {
        cancelLearning()
        stopPreview()
        privacy.toggleInstant()
        if protectionCoordinator != nil { updateRuleShield(); return }
        if !privacy.instant {
            if enabled { updateShield() } else { status = "Ready when you are" }
        }
    }

    func learnMovement() {
        guard canRecenter, !privacy.instant else {
            learningNotice = "Start head tracking and connect your AirPods first."
            return
        }
        recenter()
        guard calibrated else { return }
        calibration = AdaptiveCalibration()
        suggestedComfort = nil
        learningNotice = nil
        learningProgress = 0
        learningStarted = ProcessInfo.processInfo.systemUptime
        learning = true
        clearOverlay()
    }

    func cancelLearning(message: String? = nil) {
        guard learning else { return }
        learning = false
        learningProgress = 0
        learningNotice = message
    }

    func applyCalibration() {
        guard let suggestedComfort else { return }
        comfort = suggestedComfort
        self.suggestedComfort = nil
        learningNotice = "Sensitivity updated. Recenter whenever your sitting position changes."
        updateShield()
    }

    @discardableResult func beginHeadSetup() -> Bool {
        guard !headSetupActive, !privacy.instant else { return false }
        setupSnapshot = HeadSetupSnapshot(enabled: enabled, comfort: comfort, center: center,
                                          source: sourceLocation, generation: motionReferenceGeneration, calibrated: calibrated,
                                          everCalibrated: everCalibrated, dismissedForLoss: dismissedForLoss,
                                          ruleResponses: ruleHeadResponses)
        cancelLearning()
        suggestedComfort = nil
        learningNotice = nil
        headSetupActive = true
        stopPreview()
        clearOverlay()
        return true
    }

    func finishHeadSetup(completed: Bool) {
        guard let snapshot = setupSnapshot else { return }
        setupSnapshot = nil
        cancelLearning()
        suggestedComfort = nil
        learningNotice = nil
        headSetupActive = false
        if completed, canRecenter {
            recenter()
            saveAppearance("headSetupCompleted.v1", true)
        } else if snapshot.enabled && enabled {
            comfort = snapshot.comfort
            center = snapshot.source == sourceLocation && snapshot.generation == motionReferenceGeneration ? snapshot.center : nil
            calibrated = snapshot.calibrated && center != nil && connected
            everCalibrated = snapshot.everCalibrated
            dismissedForLoss = snapshot.dismissedForLoss
            ruleHeadResponses = snapshot.ruleResponses
            refreshResponse()
            if let center, let latest { offset = HeadOffset.between(center: center, current: latest) }
        } else {
            comfort = snapshot.comfort
            stop()
        }
        updateShield()
    }

    func previewShield() {
        guard let coordinator = protectionCoordinator else { return }
        cancelLearning(); stopPreview(); previewing = true
        coordinator.setTransient(previewRuleID, name: "Preview", active: true)
        previewEnd = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.stopPreview(); self?.updateShield()
        }
    }

    private func stopPreview(immediate: Bool = true) {
        previewEnd?.cancel(); previewEnd = nil; previewing = false
        protectionCoordinator?.setTransient(previewRuleID, name: "Preview", active: false)
    }

    func openMotionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")!)
    }

    func requestScreenPermission() {
        guard !rulePermissions.screenCheckPending else { return }
        if !screenAccess() && !screenPermission { _ = CGRequestScreenCaptureAccess() }
        refreshRulePermissions(retryRejectedCapture: true)
        verifyScreenPermission()
        if !screenPermission {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func restartForScreenPermission() {
        guard !restarting else { return }
        restarting = true
        stop()
        UserDefaults.standard.set(true, forKey: "showControlsAfterRelaunch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard application != nil, error == nil else {
                    UserDefaults.standard.removeObject(forKey: "showControlsAfterRelaunch")
                    self?.restarting = false
                    self?.captureNotice = "Could not restart QuietGlass. Quit and reopen the app."
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func recordCapturePermissionFailure() {
        screenPermissionVerifier.cancel()
        rulePermissions.screenCheckPending = false
        rulePermissions.rejectCapture(screenPreflight: screenAccess())
        protectionCoordinator?.send(.permission(.screen, granted: false))
    }

    func verifyScreenPermission() {
        guard startsPermissionSensors, !shuttingDown, !screenPermissionVerifier.isChecking else { return }
        refreshRulePermissions()
        rulePermissions.screenCheckPending = true
        rulePermissions.screenCheckUnavailable = false
        screenPermissionVerifier.start { [weak self] granted in
            guard let self, !self.shuttingDown else { return }
            self.rulePermissions.completeScreenCheck(granted: granted)
            self.protectionCoordinator?.send(.permission(.screen, granted: self.rulePermissions.captureAllowed))
            if granted == true {
                self.saveAppearance("screenAccessPreviouslyGranted", true)
                self.ruleExecutor.retryCapture()
            }
        }
    }

    func refreshRulePermissions(retryRejectedCapture: Bool = false) {
        let previous = rulePermissions
        var current = previous
        let retry = current.refresh(screen: screenAccess(), camera: cameraPermission(), retryRejectedCapture: retryRejectedCapture)
        guard current != previous else { return }
        rulePermissions = current
        protectionCoordinator?.send([.permission(.screen, granted: current.captureAllowed), .permission(.camera, granted: current.cameraGranted)])
        if current.screenGranted != previous.screenGranted {
            captureNotice = nil
            if current.screenGranted {
                saveAppearance("screenAccessPreviouslyGranted", true)
                status = "Ready when you are"
                if enabled { updateShield() }
            } else {
                stopPreview()
                clearOverlay()
                status = "Screen access needed"
            }
        }
        if current.cameraGranted != previous.cameraGranted, startsPermissionSensors {
            if current.cameraGranted {
                if nearby.canRetry { nearby.retry() }
                startCameraTracking()
            } else {
                cameraTracking.stop()
                if let document = protectionCoordinator?.document { nearbyRuleAdapter?.configure(document) }
            }
        }
        if retry { ruleExecutor.retryCapture() }
        if previous.screenVerifiedByCaptureAPI && !current.screenVerifiedByCaptureAPI {
            verifyScreenPermission()
        }
    }

    private func heartbeat() {
        refreshRulePermissions()
        guard enabled, !motionLifecyclePaused else { return }
        if trackingSource == .camera { return }
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        if auth == .denied || auth == .restricted {
            stop()
            status = "Motion permission needed"
            detail = "Allow QuietGlass in Privacy & Security → Motion & Fitness, then start again."
            return
        }
        if ProcessInfo.processInfo.systemUptime - lastSample > 1.5 {
            cancelLearning(message: "Motion was interrupted. Reconnect your AirPods and try again.")
            if connected {
                motionReferenceGeneration += 1
                invalidateDisplayCalibration()
                connected = false
                center = nil
                calibrated = false
                detail = "Motion stopped. Wear your AirPods and recenter when they reconnect."
            }
            if !everCalibrated { status = "Waiting for AirPods motion" }
            beginMotionIfAvailable()
            updateShield()
        }
        if learning {
            learningProgress = min(1, (ProcessInfo.processInfo.systemUptime - learningStarted) / 8)
            if learningProgress >= 1 {
                learning = false
                suggestedComfort = calibration.recommendation
                learningNotice = suggestedComfort == nil ? "Too much motion or too few samples. Face your screen and try again." : "Review the suggested angle before applying it."
                updateShield()
            }
        }
    }

    private func prepareForSleep() {
        motionReferenceGeneration += 1
        invalidateDisplayCalibration()
        cancelLearning(message: "Calibration stopped while your Mac slept.")
        nearby.suspend(for: .systemSleep)
        pauseCamera(for: .systemSleep)
        if let coordinator = protectionCoordinator { coordinator.suspend() } else { privacy.dismissAll() }
        if motionHasStarted { motionRunGeneration += 1; motion.stopDeviceMotionUpdates() }
        center = nil
        latest = nil
        connected = false
        calibrated = false
        stopPreview()
        clearOverlay()
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.beginMotionIfAvailable() }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            guard let self, self.enabled, self.trackingSource == .airPods else { return }
            self.motionReferenceGeneration += 1
            self.invalidateDisplayCalibration()
            self.cancelLearning(message: "AirPods disconnected. Reconnect and try again.")
            self.connected = false
            self.calibrated = false
            self.center = nil
            self.latest = nil
            self.detail = "AirPods disconnected. Face the screen and recenter after reconnecting."
            self.updateShield()
        }
    }

    private func refreshResponse() {
        cameraTracking.comfort = comfort; cameraTracking.transition = transition
    }

    private func appearanceValues() -> [String: Any] {
        guard let data = protectionCoordinator?.document.preferences.appearance else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }
    private func saveAppearance(_ key: String, _ value: Any) {
        guard !syncingRules else { return }
        guard let coordinator = protectionCoordinator else { return }
        var doc = coordinator.document
        var appearance = appearanceValues(); appearance[key] = value
        do {
            doc.preferences.appearance = try PropertyListSerialization.data(fromPropertyList: appearance, format: .binary, options: 0)
            try coordinator.save(doc)
        } catch { captureNotice = "Protection rules could not be saved. Your previous rules are still in use." }
    }
    func presentationPreference(_ key: String) -> Any? {
        return appearanceValues()[key]
    }
    func setPresentationPreference(_ key: String, _ value: Any) { saveAppearance(key, value) }
    private func save(_ key: String, _ value: Double) {
        guard !syncingRules else { return }
        guard let coordinator = protectionCoordinator else { return }
        var doc = coordinator.document
        let previous = doc.preferences.defaultBlur
        switch key {
        case "comfort": doc.preferences.defaultBlur.comfort = value
        case "transition": doc.preferences.defaultBlur.transition = value
        case "blur": doc.preferences.defaultBlur.radius = value
        default: saveAppearance(key, value); return
        }
        let previousStrong = AppProtectionMode.stronger.settings(comfort: previous.comfort, transition: previous.transition, blur: previous.radius)
        let strongParameters = BlurParameters(radius: previousStrong.blur, comfort: previousStrong.comfort, transition: previousStrong.transition)
        for index in doc.rules.indices {
            if case .blur(let parameters, let peek) = doc.rules[index].action, parameters == previous {
                doc.rules[index].action = .blur(doc.preferences.defaultBlur, peek: peek)
            } else if case .headTurn = doc.rules[index].trigger, doc.rules[index].priority == 100,
                      case .blur(let parameters, _) = doc.rules[index].action, parameters == strongParameters,
                      doc.rules[index].guards.contains(where: { if case .appCondition = $0 { return true }; return false }) {
                let defaults = doc.preferences.defaultBlur
                let strong = AppProtectionMode.stronger.settings(comfort: defaults.comfort, transition: defaults.transition, blur: defaults.radius)
                doc.rules[index].action = .blur(BlurParameters(radius: strong.blur, comfort: strong.comfort, transition: strong.transition), peek: nil)
            }
        }
        do { try coordinator.save(doc) }
        catch { captureNotice = "Protection rules could not be saved. Your previous rules are still in use." }
    }

    private func syncRuleConfiguration() {
        guard let coordinator = protectionCoordinator, !syncingRules, !shuttingDown else { return }
        syncingRules = true
        defer { syncingRules = false }
        let doc = coordinator.document
        let defaults = doc.preferences.defaultBlur
        if comfort != defaults.comfort { comfort = defaults.comfort }
        if transition != defaults.transition { transition = defaults.transition }
        if blur != defaults.radius { blur = defaults.radius }
        let appearance = appearanceValues()
        if let demo = appearance["includeBlurInCaptures"] as? Bool, demoMode != demo { demoMode = demo }
        ruleExecutor.includeInCaptures = demoMode
        let heads = doc.rules.filter { if case .headTurn = $0.trigger { return true }; return false }
        let primary = heads.first(where: { rule in if case .headTurn(.airPods) = rule.trigger { return rule.isEnabled }; return false }) ?? heads.first(where: \.isEnabled) ?? heads.first
        if let primary, case .headTurn(let source) = primary.trigger {
            if source != trackingSource && enabled { stop() }
            trackingSource = source
        }
        let displayMode: Bool = {
            guard trackingSource == .airPods else { return false }
            return heads.contains { rule in if case .headTurn(.airPods) = rule.trigger, case .display = rule.scope { return rule.isEnabled }; return false }
        }()
        if perDisplayTracking != displayMode { perDisplayTracking = displayMode }
        let recenter = doc.preferences.recenterShortcut
        if !shortcuts.configureRules(ShortcutRegistry(rules: doc.rules, recenter: recenter), recenter: recenter, activeManualRules: coordinator.activeManualRuleIDs) {
            shortcutNotice = "That shortcut is already in use. Try another combination."
        }
        ruleExecutor.configureTextRules(doc.rules)
        nearbyRuleAdapter?.configure(doc)
        cameraTracking.configureRules(heads)
        let airIDs = Set(heads.filter { rule in if case .headTurn(.airPods) = rule.trigger { return rule.isEnabled }; return false }.map(\.id))
        ruleHeadResponses = ruleHeadResponses.filter { airIDs.contains($0.key) }
        ruleDisplayTracking = ruleDisplayTracking.filter { airIDs.contains($0.key) }
        ruleDisplayCenters = ruleDisplayCenters.filter { airIDs.contains($0.key) }
        let wantsCamera = heads.contains { rule in if case .headTurn(.camera) = rule.trigger { return rule.isEnabled }; return false }
        if wantsCamera && !cameraTracking.running && coordinator.plan.state == .running { startCameraTracking() }
        if !wantsCamera && cameraTracking.running { cameraTracking.stop() }
        let wantsHead = heads.contains { $0.isEnabled }
        if wantsHead && !enabled && coordinator.plan.state == .running { start() }
        if !wantsHead && enabled { stop() }
        privacy.projectRules()
        refreshResponse()
        updateRuleShield()
    }
    private func setHeadRulesEnabled(_ active: Bool) {
        guard let coordinator = protectionCoordinator, !syncingRules else { return }
        var rules = coordinator.document.rules
        for index in rules.indices {
            if case .headTurn(let source) = rules[index].trigger, !active || source == trackingSource { rules[index].isEnabled = active }
        }
        do { try coordinator.saveRules(rules) }
        catch { captureNotice = "Protection rules could not be saved. Your previous rules are still in use." }
    }
    private func reconcileMotionLifecycle(_ state: ProtectionEngineState) {
        guard motionHasStarted else { return }
        let pause: Bool = { if case .paused = state { return true }; return state == .suspended }()
        guard pause != motionLifecyclePaused else { return }
        motionLifecyclePaused = pause
        if pause {
            motionAwaitingSample = true
            motionRunGeneration += 1
            motion.stopDeviceMotionUpdates(); motion.stopConnectionStatusUpdates()
        } else if enabled && trackingSource == .airPods {
            motion.startConnectionStatusUpdates(); beginMotionIfAvailable()
        }
    }

    private func receiveRulePlan(_ plan: ProtectionPlan) {
        reconcileMotionLifecycle(plan.state)
        privacy.projectRules()
        nearbyRuleAdapter?.present(plan)
        let value = plan.displays.map(\.fullScreenCoverage).max() ?? 0
        if coverage != value { coverage = value }
        if plan.state == .cleared { nearby.suspend(for: .globalPause); pauseCamera(for: .globalPause) }
        else if case .paused = plan.state { nearby.suspend(for: .globalPause); pauseCamera(for: .globalPause) }
        else if plan.state == .running {
            nearby.resume(after: .globalPause); resumeCamera(after: .globalPause)
            if !enabled && !syncingRules && !headSetupActive,
               protectionCoordinator?.document.rules.contains(where: { if case .headTurn = $0.trigger { return $0.isEnabled }; return false }) == true { start() }
        }
        if plan.hasProtection {
            status = QG("Protected by %@", plan.activeRules.map { QG($0.name) }.joined(separator: ", "))
        } else if !plan.warnings.isEmpty {
            status = QG("Warning from %@", plan.warnings.map { QG($0.rule.name) }.joined(separator: ", "))
        } else if case .paused = plan.state { status = "Paused" }
        else if plan.state == .cleared { status = "Shield dismissed" }
        else if enabled && trackingSource == .camera { status = cameraTracking.message }
        else if enabled && !calibrated { status = "Center your gaze" }
        else { status = enabled ? "Watching your head motion" : "Ready when you are" }
    }
    private func updateRuleShield() {
        guard let coordinator = protectionCoordinator else { return }
        coordinator.send(ruleShieldEvents())
        receiveRulePlan(coordinator.plan)
    }
    private func ruleShieldEvents(resuming: Bool = false) -> [ProtectionEvent] {
        guard let coordinator = protectionCoordinator else { return [] }
        let motionAllowed: Bool
        if enabled && trackingSource == .airPods {
            let authorization = CMHeadphoneMotionManager.authorizationStatus()
            motionAllowed = authorization != .denied && authorization != .restricted
        } else { motionAllowed = false }
        let cameraAllowed = cameraPermission()
        var events: [ProtectionEvent] = [.permission(.screen, granted: rulePermissions.captureAllowed), .permission(.motion, granted: motionAllowed), .permission(.camera, granted: cameraAllowed)]
        for rule in coordinator.document.rules {
            guard rule.isEnabled, case .headTurn(let source) = rule.trigger, case .blur(let parameters, _) = rule.action else { continue }
            var value = 0.0, values: [UInt32: Double] = [:]
            var isCalibrated = false, direction = ShieldDirection.from(offset)
            if source == .camera {
                if cameraTracking.running && cameraPauses.isEmpty, let policy = cameraTracking.rulePolicies[rule.id] {
                    value = policy.coverage; isCalibrated = policy.calibrated || cameraTracking.calibratedRuleIDs.contains(rule.id)
                    direction = .from(policy.offset)
                } else if resuming && cameraTracking.calibratedRuleIDs.contains(rule.id) {
                    value = 1; isCalibrated = true
                }
            } else if enabled && trackingSource == .airPods && !learning && !headSetupActive {
                isCalibrated = calibrated || everCalibrated
                if !connected || !calibrated || motionAwaitingSample { value = everCalibrated && !dismissedForLoss ? 1 : 0 }
                else if case .display = rule.scope, let latest, !connectedDisplays.isEmpty,
                        connectedDisplays.allSatisfy({ displayCalibrationIDs.contains($0.id) }) {
                    var tracker = ruleDisplayTracking[rule.id] ?? DisplayHeadTracking()
                    if ruleDisplayCenters[rule.id] != displayTracking.centers {
                        for (id, center) in displayTracking.centers { tracker.calibrate(id, at: center) }
                        ruleDisplayCenters[rule.id] = displayTracking.centers
                    }
                    values = tracker.coverage(current: latest, displays: connectedDisplays.map(\.id), comfort: parameters.comfort, transition: parameters.transition)
                    ruleDisplayTracking[rule.id] = tracker; value = values.values.max() ?? 0
                } else {
                    var response = ruleHeadResponses[rule.id] ?? ShieldResponse()
                    response.comfort = parameters.comfort; response.transition = parameters.transition
                    value = response.coverage(angle: offset.angle); ruleHeadResponses[rule.id] = response
                }
            }
            events.append(.headRuleCoverage(rule.id, coverage: value, displays: values, calibrated: isCalibrated, direction: direction))
        }
        return events
    }
    private func handleRuleShortcut(_ binding: RuleShortcut, pressed: Bool) {
        guard let coordinator = protectionCoordinator else { return }
        if binding.operation == .peek { coordinator.send(.peek(binding.ruleID, held: pressed)); return }
        guard pressed, let rule = coordinator.document.rules.first(where: { $0.id == binding.ruleID }) else { return }
        if case .region(let ref, _, _) = rule.scope, ref.bundleID == "$selection" { privacy.chooseArea(recipeID: rule.id) }
        else if case .window(let ref) = rule.scope, ref.bundleID == "$selection" { privacy.chooseWindow(recipeID: rule.id) }
        else { privacy.ruleSources?.refresh(); coordinator.toggleManual(rule.id) }
    }
    func shutdown() {
        shuttingDown = true
        screenPermissionVerifier.cancel()
        ruleRegionMarker.close()
        endRuleRegionSelection()
        protectionCoordinator?.shutdown()
        updates.shutdown()
        protectionCheck.close()
        nearby.shutdown()
        stop()
        privacy.shutdown()
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
