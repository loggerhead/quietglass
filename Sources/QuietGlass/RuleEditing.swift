import Foundation
import ShieldCore

enum RuleTriggerKind: String, CaseIterable, Identifiable {
    case manual, headTurn, extraFace, sensitiveText, appEvent, windowTitle
    var id: Self { self }
    var title: String {
        switch self {
        case .manual: return "I turn it on"
        case .headTurn: return "I look away"
        case .extraFace: return "Someone is nearby"
        case .sensitiveText: return "Sensitive text appears"
        case .appEvent: return "An app is in use"
        case .windowTitle: return "A saved window appears"
        }
    }
    init(_ trigger: ProtectionTrigger) {
        switch trigger {
        case .manual: self = .manual
        case .headTurn: self = .headTurn
        case .extraFace: self = .extraFace
        case .sensitiveText: self = .sensitiveText
        case .appEvent: self = .appEvent
        case .windowTitle: self = .windowTitle
        }
    }
}
enum RuleScopeKind: String, CaseIterable, Identifiable {
    case allDisplays, displays, selectedRegion, window, region, detectedText, focus
    var id: Self { self }
    var title: String {
        switch self {
        case .allDisplays: return "All displays"
        case .displays: return "Selected displays"
        case .selectedRegion: return "Select region"
        case .window: return "An app’s windows"
        case .region: return "Part of a window"
        case .detectedText: return "Matching text"
        case .focus: return "Everything except my current window"
        }
    }
}
enum RuleActionKind: String, CaseIterable, Identifiable {
    case blur, warnThenBlur, warnOnly, pause
    var id: Self { self }
    var title: String {
        switch self {
        case .blur: return "Blur"
        case .warnThenBlur: return "Warn, then blur"
        case .warnOnly: return "Warn only"
        case .pause: return "Pause other protection"
        }
    }
}

/// Editable representation of the four rule components, with validation shared by the engine.
struct RuleDraft {
    let id: UUID
    let createdAt: Date
    var name: String
    var enabled: Bool
    var priority: Int
    var triggerKind: RuleTriggerKind
    var scopeKind: RuleScopeKind = .allDisplays
    var actionKind: RuleActionKind = .blur
    var source: HeadTrackingSource = .airPods
    var detection: NearbyDetection = .facingScreen
    var types: Set<SensitiveTextType> = [.credentials]
    var phraseText = ""
    var triggerBundle = ""
    var appEvent: AppEvent = .activated
    var targetBundle = ""
    var titleDigest = ""
    var windowID: UInt32?
    var ownerPID: Int32?
    var displayIDs: Set<UInt32> = []
    var regionDisplayID: UInt32 = 0
    var rectangle = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    var rememberRegion = false
    var blur = BlurParameters()
    var delay = 120.0
    var sound = true
    var indefinitePause = true
    var pauseDuration = 300.0
    var pauseHeadsOnly = false
    var shortcutEnabled = false
    var shortcut: ShortcutBinding?
    var peekEnabled = false
    var peekShortcut: ShortcutBinding?
    var ownerVerification = false
    var screenPermission = true
    var cameraPermission = false
    var motionPermission = false
    var calibration = false
    var notPaused = true
    var appConditionEnabled = false
    var appCondition = ""
    var timeEnabled = false
    var startHour = 9, startMinute = 0, endHour = 17, endMinute = 0
    private var guardOrder: [ProtectionGuard] = []

    init(rule: ProtectionRule) {
        guardOrder = rule.guards
        id = rule.id; createdAt = rule.createdAt; name = rule.name; enabled = rule.isEnabled
        priority = rule.priority; triggerKind = RuleTriggerKind(rule.trigger)
        switch rule.trigger {
        case .manual(let binding): shortcutEnabled = binding != nil; if let binding { shortcut = binding }
        case .headTurn(let source): self.source = source
        case .extraFace(let detection): self.detection = detection
        case .sensitiveText(let types, let phrases): self.types = types; phraseText = phrases.joined(separator: "\n")
        case .appEvent(let bundle, let event): triggerBundle = bundle; appEvent = event
        case .windowTitle(let bundle, let digest): triggerBundle = bundle; titleDigest = digest
        }
        switch rule.scope {
        case .allDisplays: scopeKind = .allDisplays
        case .display(let ids): scopeKind = .displays; displayIDs = Set(ids)
        case .displayRegion(let id, let rect): scopeKind = .selectedRegion; regionDisplayID = id; rectangle = rect
        case .window(let ref): scopeKind = .window; setWindow(ref)
        case .region(let ref, let rect, let persistence):
            scopeKind = .region; setWindow(ref); rectangle = rect; rememberRegion = persistence == .rememberWindowTitle
        case .detectedText: scopeKind = .detectedText
        case .allDisplaysExceptActiveWindow: scopeKind = .focus
        }
        switch rule.action {
        case .blur(let params, let peek):
            actionKind = .blur; blur = params; peekEnabled = peek != nil
            if case .hold(let shortcut) = peek { peekShortcut = shortcut }
        case .warnThenBlur(let delay, let sound): actionKind = .warnThenBlur; self.delay = delay; self.sound = sound
        case .warnOnly(let delay, let sound): actionKind = .warnOnly; self.delay = delay; self.sound = sound
        case .pauseOtherProtection(let duration, let target):
            actionKind = .pause; indefinitePause = duration == nil; pauseDuration = duration ?? 300; pauseHeadsOnly = target == .headTurn
        }
        screenPermission = false
        for condition in rule.guards {
            switch condition {
            case .ownerVerification: ownerVerification = true
            case .permission(.screen): screenPermission = true
            case .permission(.camera): cameraPermission = true
            case .permission(.motion): motionPermission = true
            case .calibrationRequired: calibration = true
            case .notPaused: break
            case .appCondition(let bundle): appConditionEnabled = true; appCondition = bundle
            case .timeWindow(let start, let end):
                timeEnabled = true; startHour = start.hour ?? 9; startMinute = start.minute ?? 0
                endHour = end.hour ?? 17; endMinute = end.minute ?? 0
            }
        }
        notPaused = rule.guards.contains(.notPaused)
    }
    init(parameters: BlurParameters = BlurParameters()) {
        self.init(rule: ProtectionRule(name: "New rule", trigger: .manual(shortcut: nil), scope: .allDisplays,
                                      action: .blur(parameters, peek: nil), guards: [.permission(.screen), .notPaused]))
    }
    mutating func setWindow(_ ref: ProtectedWindowRef) {
        targetBundle = ref.bundleID; windowID = ref.windowID; ownerPID = ref.ownerPID
        if let digest = ref.titleDigest { titleDigest = digest }
        if triggerKind == .windowTitle { triggerBundle = ref.bundleID }
    }
    mutating func setDisplayRegion(_ selection: SelectedDisplayRegion) {
        scopeKind = .selectedRegion; regionDisplayID = selection.displayID; rectangle = selection.normalizedRect
        targetBundle = ""; windowID = nil; ownerPID = nil; titleDigest = ""; rememberRegion = false
    }
    mutating func selectTrigger(_ kind: RuleTriggerKind) {
        triggerKind = kind; actionKind = kind == .extraFace ? .warnThenBlur : .blur
        if kind != .manual { shortcutEnabled = false; peekEnabled = false }
        if kind != .extraFace { ownerVerification = false }
        calibration = kind == .headTurn
        cameraPermission = kind == .extraFace || (kind == .headTurn && source == .camera)
        motionPermission = kind == .headTurn && source == .airPods
        if !allowedScopes.contains(scopeKind) { scopeKind = allowedScopes.first ?? .allDisplays }
        if kind == .windowTitle { rememberRegion = true }
    }
    private var reference: ProtectedWindowRef {
        ProtectedWindowRef(bundleID: targetBundle, windowID: windowID, ownerPID: ownerPID,
                           titleDigest: titleDigest.isEmpty ? nil : titleDigest)
    }
    private func scope(_ kind: RuleScopeKind, reference: ProtectedWindowRef) -> ProtectionScope {
        switch kind {
        case .allDisplays: return .allDisplays
        case .displays: return .display(ids: displayIDs.sorted())
        case .selectedRegion: return .displayRegion(id: regionDisplayID, normalizedRect: rectangle)
        case .window: return .window(reference)
        case .region:
            var ref = reference
            if rememberRegion { ref.windowID = nil; ref.ownerPID = nil }
            return .region(ref, normalizedRect: rectangle, persistence: rememberRegion ? .rememberWindowTitle : .session)
        case .detectedText: return .detectedText
        case .focus: return .allDisplaysExceptActiveWindow
        }
    }
    var rule: ProtectionRule {
        let trigger: ProtectionTrigger
        switch triggerKind {
        case .manual: trigger = .manual(shortcut: shortcutEnabled ? shortcut : nil)
        case .headTurn: trigger = .headTurn(source: source)
        case .extraFace: trigger = .extraFace(detection: detection)
        case .sensitiveText: trigger = .sensitiveText(types: types, phrases: SensitiveText.cleanPhrases(phraseText.components(separatedBy: .newlines)))
        case .appEvent: trigger = .appEvent(bundleID: triggerBundle, event: appEvent)
        case .windowTitle: trigger = .windowTitle(bundleID: triggerBundle, titleDigest: titleDigest)
        }
        let action: ProtectionAction
        switch actionKind {
        case .blur: action = .blur(blur, peek: peekEnabled ? peekShortcut.map(PeekConfiguration.hold) : nil)
        case .warnThenBlur: action = .warnThenBlur(delay: delay, sound: sound)
        case .warnOnly: action = .warnOnly(delay: delay, sound: sound)
        case .pause: action = .pauseOtherProtection(duration: indefinitePause ? nil : pauseDuration, target: pauseHeadsOnly ? .headTurn : .all)
        }
        var guards: [ProtectionGuard] = []
        if ownerVerification { guards.append(.ownerVerification) }
        if screenPermission { guards.append(.permission(.screen)) }
        if cameraPermission { guards.append(.permission(.camera)) }
        if motionPermission { guards.append(.permission(.motion)) }
        if calibration { guards.append(.calibrationRequired) }
        if appConditionEnabled { guards.append(.appCondition(bundleID: appCondition)) }
        if timeEnabled { guards.append(.timeWindow(start: DateComponents(hour: startHour, minute: startMinute), end: DateComponents(hour: endHour, minute: endMinute))) }
        if notPaused { guards.append(.notPaused) }
        let ordered = guardOrder.filter { guards.contains($0) } + guards.filter { !guardOrder.contains($0) }
        return ProtectionRule(id: id, name: name, isEnabled: enabled, priority: priority, createdAt: createdAt,
                              trigger: trigger, scope: scope(scopeKind, reference: reference), action: action, guards: ordered)
    }
    private var probe: ProtectionRule {
        var candidate = rule
        if triggerKind == .windowTitle { candidate.trigger = .windowTitle(bundleID: "example.app", titleDigest: String(repeating: "a", count: 64)) }
        candidate.guards = []; candidate.action = .blur(BlurParameters(), peek: nil)
        return candidate
    }
    var allowedScopes: [RuleScopeKind] {
        let ref = ProtectedWindowRef(bundleID: "example.app", titleDigest: String(repeating: "a", count: 64))
        return RuleScopeKind.allCases.filter { kind in
            var candidate = probe; candidate.scope = scope(kind, reference: ref)
            return !ProtectionRuleValidator.validate(candidate).contains(.invalidCombination)
        }
    }
    var allowedActions: [RuleActionKind] {
        let ref = ProtectedWindowRef(bundleID: "example.app", titleDigest: String(repeating: "a", count: 64))
        return RuleActionKind.allCases.filter { kind in
            var candidate = probe; candidate.scope = scope(allowedScopes.first ?? .allDisplays, reference: ref)
            switch kind {
            case .blur: candidate.action = .blur(BlurParameters(), peek: nil)
            case .warnThenBlur: candidate.action = .warnThenBlur(delay: 120, sound: true)
            case .warnOnly: candidate.action = .warnOnly(delay: 120, sound: true)
            case .pause: candidate.action = .pauseOtherProtection(duration: nil)
            }
            return !ProtectionRuleValidator.validate(candidate).contains(.invalidCombination)
        }
    }
    var errors: [RuleValidationError] {
        var errors = ProtectionRuleValidator.validate(rule)
        if chooseOnActivation && triggerKind != .manual { errors.append(.invalidScope) }
        if chooseOnActivation && peekEnabled { errors.append(.invalidPeek) }
        if shortcutEnabled && shortcut == nil || peekEnabled && peekShortcut == nil { errors.append(.invalidShortcut) }
        return errors
    }
    var canSave: Bool { errors.isEmpty }
    var chooseOnActivation: Bool {
        get { targetBundle == "$selection" }
        set {
            targetBundle = newValue ? "$selection" : ""; windowID = nil; ownerPID = nil; titleDigest = ""
            if newValue { rememberRegion = false; peekEnabled = false }
        }
    }
}

extension RuleValidationError {
    var message: String {
        switch self {
        case .emptyName: return "Give this rule a name."
        case .invalidCombination: return "This combination is not available. Choose another range or response."
        case .invalidPeek: return "Hold to peek works with a manual blur that stays on."
        case .invalidOwnerGuard: return "Face recognition can only be used with nearby-person detection."
        case .invalidCalibrationGuard: return "Calibration is only needed for head-tracking rules."
        case .invalidScope: return "Choose a display, window, or area to continue."
        case .invalidParameters: return "Enter valid blur, angle, and duration values."
        case .invalidTrigger: return "Complete the application, title, or sensitive-text trigger."
        case .invalidTimeWindow: return "Choose a valid start and end time."
        case .invalidShortcut: return "Choose a shortcut with modifiers; Escape is reserved for clearing protection."
        }
    }
}
