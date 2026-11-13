import Foundation
import CoreGraphics

public enum HeadTrackingSource: String, Codable, CaseIterable, Identifiable {
    case airPods, camera
    public var id: String { rawValue }
    public var title: String { self == .airPods ? "AirPods" : "Camera" }
}

public enum NearbyDetection: String, Codable, CaseIterable, Identifiable {
    case facingScreen, anyFace
    public var id: String { rawValue }
    public var title: String { self == .facingScreen ? "Facing screen" : "Any extra face" }
}

public struct ShortcutBinding: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

public enum SensitiveTextType: String, Codable, CaseIterable {
    case credentials, emailAddresses, paymentCards
    public var option: SensitiveTextOptions {
        switch self {
        case .credentials: return .credentials
        case .emailAddresses: return .emailAddresses
        case .paymentCards: return .paymentCards
        }
    }
}

public enum AppEvent: String, Codable, CaseIterable { case activated, windowOpened }
public enum RegionPersistence: String, Codable { case session, rememberWindowTitle }
public enum PermissionKind: String, Codable, Hashable { case screen, camera, motion }

/// Stable matching data only. Window titles and screen contents never belong here.
public struct ProtectedWindowRef: Codable, Equatable, Hashable {
    public var bundleID: String
    public var windowID: UInt32?
    public var ownerPID: Int32?
    public var titleDigest: String?
    public init(bundleID: String, windowID: UInt32? = nil, ownerPID: Int32? = nil, titleDigest: String? = nil) {
        self.bundleID = bundleID; self.windowID = windowID; self.ownerPID = ownerPID; self.titleDigest = titleDigest
    }
}

public struct BlurParameters: Codable, Equatable {
    public var radius: Double
    public var comfort: Double
    public var transition: Double
    public init(radius: Double = 28, comfort: Double = 15, transition: Double = 18) {
        self.radius = radius; self.comfort = comfort; self.transition = transition
    }
}

public enum PeekConfiguration: Codable, Equatable { case hold(ShortcutBinding) }
public enum ProtectionPauseTarget: String, Codable { case all, headTurn }
public enum ProtectionTrigger: Codable, Equatable {
    case manual(shortcut: ShortcutBinding?)
    case headTurn(source: HeadTrackingSource)
    case extraFace(detection: NearbyDetection)
    case sensitiveText(types: Set<SensitiveTextType>, phrases: [String])
    case appEvent(bundleID: String, event: AppEvent)
    case windowTitle(bundleID: String, titleDigest: String)
}
public enum ProtectionScope: Codable, Equatable {
    case allDisplays
    case display(ids: [UInt32])
    case displayRegion(id: UInt32, normalizedRect: CGRect)
    case window(ProtectedWindowRef)
    case region(ProtectedWindowRef, normalizedRect: CGRect, persistence: RegionPersistence)
    case detectedText
    case allDisplaysExceptActiveWindow
}
public enum ProtectionAction: Codable, Equatable {
    case blur(BlurParameters, peek: PeekConfiguration?)
    case warnThenBlur(delay: TimeInterval, sound: Bool)
    case warnOnly(delay: TimeInterval, sound: Bool)
    case pauseOtherProtection(duration: TimeInterval?, target: ProtectionPauseTarget = .all)
}
public enum ProtectionGuard: Codable, Equatable {
    case ownerVerification
    case permission(PermissionKind)
    case calibrationRequired
    case appCondition(bundleID: String)
    case timeWindow(start: DateComponents, end: DateComponents)
    case notPaused
}

public struct ProtectionRule: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var priority: Int
    public let createdAt: Date
    public var trigger: ProtectionTrigger
    public var scope: ProtectionScope
    public var action: ProtectionAction
    public var guards: [ProtectionGuard]
    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, priority: Int = 0,
                createdAt: Date = Date(), trigger: ProtectionTrigger, scope: ProtectionScope,
                action: ProtectionAction = .blur(BlurParameters(), peek: nil), guards: [ProtectionGuard] = []) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.priority = priority
        self.createdAt = createdAt; self.trigger = trigger; self.scope = scope; self.action = action; self.guards = guards
    }
}

public enum RuleValidationError: String, Error, Equatable, CaseIterable {
    case emptyName, invalidCombination, invalidPeek, invalidOwnerGuard, invalidCalibrationGuard
    case invalidScope, invalidParameters, invalidTrigger, invalidTimeWindow, invalidShortcut
}

public enum ProtectionRuleValidator {
    public static func validate(_ rule: ProtectionRule) -> [RuleValidationError] {
        var errors: [RuleValidationError] = []
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.emptyName) }
        let scopeAllowed: Bool
        let actionAllowed: Bool
        switch rule.trigger {
        case .manual(let shortcut):
            if let shortcut, !validShortcut(shortcut) { errors.append(.invalidShortcut) }
            switch rule.scope { case .detectedText: scopeAllowed = false; default: scopeAllowed = true }
            if case .blur = rule.action { actionAllowed = true } else { actionAllowed = false }
        case .headTurn:
            switch rule.scope { case .allDisplays, .display: scopeAllowed = true; default: scopeAllowed = false }
            if case .blur = rule.action { actionAllowed = true } else { actionAllowed = false }
        case .extraFace:
            switch rule.scope { case .allDisplays, .window, .displayRegion: scopeAllowed = true; default: scopeAllowed = false }
            switch rule.action { case .pauseOtherProtection: actionAllowed = false; default: actionAllowed = true }
        case .sensitiveText(let types, let phrases):
            if types.isEmpty && phrases.isEmpty { errors.append(.invalidTrigger) }
            if SensitiveText.cleanPhrases(phrases) != phrases { errors.append(.invalidTrigger) }
            if case .detectedText = rule.scope { scopeAllowed = true } else { scopeAllowed = false }
            if case .blur = rule.action { actionAllowed = true } else { actionAllowed = false }
        case .appEvent(let bundleID, _):
            if bundleID.isEmpty { errors.append(.invalidTrigger) }
            switch rule.scope { case .window, .allDisplaysExceptActiveWindow: scopeAllowed = true; default: scopeAllowed = false }
            switch rule.action { case .blur, .pauseOtherProtection: actionAllowed = true; default: actionAllowed = false }
        case .windowTitle(let bundleID, let digest):
            if bundleID.isEmpty || !validDigest(digest) { errors.append(.invalidTrigger) }
            if case .region(let ref, _, _) = rule.scope,
               ref.bundleID == bundleID, ref.titleDigest == digest { scopeAllowed = true } else { scopeAllowed = false }
            if case .blur = rule.action { actionAllowed = true } else { actionAllowed = false }
        }
        if !scopeAllowed || !actionAllowed { errors.append(.invalidCombination) }
        switch rule.scope {
        case .display(let ids):
            if ids.isEmpty || Set(ids).count != ids.count { errors.append(.invalidScope) }
        case .displayRegion(let id, let rect):
            if id == 0 || !validRect(rect) { errors.append(.invalidScope) }
        case .window(let ref):
            if !validWindow(ref) { errors.append(.invalidScope) }
        case .region(let ref, let rect, let persistence):
            if !validWindow(ref) || !validRect(rect) || (persistence == .rememberWindowTitle && ref.titleDigest == nil) {
                errors.append(.invalidScope)
            }
        default: break
        }
        switch rule.action {
        case .blur(let parameters, let peek):
            if !parameters.radius.isFinite || !(10...70).contains(parameters.radius) ||
                !parameters.comfort.isFinite || !(2...30).contains(parameters.comfort) ||
                !parameters.transition.isFinite || !(5...30).contains(parameters.transition) { errors.append(.invalidParameters) }
            if let peek {
                switch rule.scope {
                case .window(let ref), .region(let ref, _, _): if ref.bundleID == "$selection" { errors.append(.invalidPeek) }
                default: break
                }
                if case .manual = rule.trigger {} else { errors.append(.invalidPeek) }
                if case .hold(let shortcut) = peek, !validShortcut(shortcut) { errors.append(.invalidShortcut) }
            }
        case .warnThenBlur(let delay, _), .warnOnly(let delay, _):
            if !delay.isFinite || delay < 0 || delay > NearbyWarningPolicy.maximumDelay { errors.append(.invalidParameters) }
        case .pauseOtherProtection(let duration, _):
            if let duration, !duration.isFinite || duration <= 0 { errors.append(.invalidParameters) }
        }
        for guardCondition in rule.guards {
            switch guardCondition {
            case .ownerVerification:
                if case .extraFace = rule.trigger {} else { errors.append(.invalidOwnerGuard) }
            case .calibrationRequired:
                if case .headTurn = rule.trigger {} else { errors.append(.invalidCalibrationGuard) }
            case .appCondition(let bundleID): if bundleID.isEmpty { errors.append(.invalidTrigger) }
            case .timeWindow(let start, let end):
                if minutes(start) == nil || minutes(end) == nil { errors.append(.invalidTimeWindow) }
            default: break
            }
        }
        return errors
    }
    public static func minutes(_ components: DateComponents) -> Int? {
        guard let hour = components.hour, let minute = components.minute,
              (0...23).contains(hour), (0...59).contains(minute),
              components.year == nil, components.month == nil, components.day == nil,
              components.second == nil, components.weekday == nil else { return nil }
        return hour * 60 + minute
    }
    public static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func validWindow(_ ref: ProtectedWindowRef) -> Bool {
        !ref.bundleID.isEmpty && (ref.titleDigest.map(validDigest) ?? true)
    }
    private static func validRect(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0 &&
            CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect)
    }
    private static func validShortcut(_ shortcut: ShortcutBinding) -> Bool {
        shortcut.keyCode != 53 && shortcut.modifiers != 0 && !shortcut.label.isEmpty
    }
}
