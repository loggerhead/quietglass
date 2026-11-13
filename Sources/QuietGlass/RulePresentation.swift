import ShieldCore

extension PermissionKind {
    var accessTitle: String {
        switch self {
        case .screen: return "Screen Recording"
        case .camera: return "Camera"
        case .motion: return "Motion & Fitness"
        }
    }
}

extension RulePermissionState {
    func missingAccessTitle(_ permissions: Set<PermissionKind>) -> String {
        [PermissionKind.screen, .camera, .motion].filter(permissions.contains)
            .map { QG($0.accessTitle) }.joined(separator: QG(", "))
    }
}

extension ProtectionPreset {
    var title: String { switch self { case .nearby: return "Respond to nearby people"; case .headTurn: return "Blur when I look away"; case .sensitiveText: return "Hide sensitive text"; case .focus: return "Focus on this window" } }
    var detail: String {
        switch self {
        case .nearby: return "Warn first, then blur after the waiting time. You can edit it to warn only."
        case .headTurn: return "Blur as you look away and restore as you face the screen. Calibrate first."
        case .sensitiveText: return "Blur matching text while leaving the rest of the screen clear."
        case .focus: return "Use by hand to keep the current window clear and blur everything else."
        }
    }
    var symbol: String {
        switch self { case .nearby: return "person.2"; case .headTurn: return "airpodspro"; case .sensitiveText: return "text.viewfinder"; case .focus: return "viewfinder" }
    }
}
extension RuleTriggerKind {
    var groupTitle: String {
        switch self {
        case .manual: return "Manual protection"
        case .headTurn: return "Head movement"
        case .extraFace: return "Nearby people"
        case .sensitiveText: return "Sensitive text"
        case .appEvent: return "Apps"
        case .windowTitle: return "Saved windows"
        }
    }
    var symbol: String {
        switch self { case .manual: return "hand.tap"; case .headTurn: return "airpodspro"; case .extraFace: return "person.2"; case .sensitiveText: return "text.viewfinder"; case .appEvent: return "app"; case .windowTitle: return "macwindow" }
    }
}
extension ProtectionReason {
    var title: String {
        switch self {
        case .manual: return "Activated manually"
        case .headTurn: return "Head turned away"
        case .extraFace: return "Someone else was detected"
        case .ownerUnverified: return "Your face has not been confirmed yet"
        case .sensitiveText: return "Sensitive information was found"
        case .appEvent: return "An app rule is active"
        case .windowTitle: return "A saved window was opened"
        case .warningEscalated: return "Blur was turned on after a warning"
        case .pauseRule: return "Paused by another rule"
        }
    }
}
extension ProtectionGuard {
    var title: String {
        switch self {
        case .ownerVerification: return "Recognize me"
        case .permission(.screen): return "Screen Recording access"
        case .permission(.camera): return "Camera access"
        case .permission(.motion): return "Motion access"
        case .calibrationRequired: return "Head tracking calibrated"
        case .appCondition: return "While using an app"
        case .timeWindow: return "Time window"
        case .notPaused: return "While protection is running"
        }
    }
}
extension ProtectionRule {
    var responseExplanation: String {
        let when: String
        switch trigger {
        case .manual: when = QG("Used by a button or shortcut.")
        case .headTurn: when = QG("Responds when you look away from the screen.")
        case .extraFace:
            when = QG(guards.contains(.ownerVerification) ? "Uses nearby-face detection and recognition of your saved face." : "Responds when another face is detected.")
        case .sensitiveText: when = QG("Responds when matching sensitive text is found.")
        case .appEvent(_, let event): when = QG(event == .activated ? "Responds while the selected app is in front." : "Responds while the selected app has open windows.")
        case .windowTitle: when = QG("Restores the selected area when a matching window appears.")
        }
        let response: String
        switch action {
        case .blur: response = QG("Blurs the chosen content.")
        case .warnThenBlur(let delay, _): response = QG("Warns first, then blurs after %g seconds.", delay)
        case .warnOnly: response = QG("Shows a warning; never blurs automatically.")
        case .pauseOtherProtection(_, let target): response = QG(target == .headTurn ? "Temporarily pauses head tracking." : "Temporarily pauses other protection.")
        }
        return QG("%@ %@", when, response)
    }
    var scopeTitle: String {
        switch scope {
        case .allDisplays: return QG("All displays")
        case .display: return QG("Selected displays")
        case .displayRegion: return QG("Selected region")
        case .window(let ref): return QG(ref.bundleID == "$selection" ? "Choose a window each time" : "An app’s windows")
        case .region(let ref, _, _): return QG(ref.bundleID == "$selection" ? "Choose an area each time" : "Part of a window")
        case .detectedText: return QG("Matching text")
        case .allDisplaysExceptActiveWindow: return QG("Everything except my current window")
        }
    }
    var actionTitle: String {
        switch action {
        case .blur: return QG("Blur")
        case .warnThenBlur: return QG("Warn, then blur")
        case .warnOnly: return QG("Warn only")
        case .pauseOtherProtection(_, let target): return QG(target == .headTurn ? "Pause head-turn rules only" : "Pause other protection")
        }
    }
}
