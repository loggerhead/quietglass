import Foundation
import CoreGraphics

public struct ProtectionDisplay: Equatable {
    public var id: UInt32
    public var frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
}

/// Geometry comes from the window adapter, after occlusion and coordinate conversion.
public struct ProtectionWindow: Equatable {
    public var reference: ProtectedWindowRef
    public var frame: CGRect
    public var occluders: [CGRect]
    public init(reference: ProtectedWindowRef, frame: CGRect, occluders: [CGRect] = []) {
        self.reference = reference; self.frame = frame; self.occluders = occluders
    }
    public func matches(_ target: ProtectedWindowRef) -> Bool {
        reference.bundleID == target.bundleID &&
        (target.windowID == nil || reference.windowID == target.windowID) &&
        (target.ownerPID == nil || reference.ownerPID == target.ownerPID) &&
        (target.titleDigest == nil || reference.titleDigest == target.titleDigest)
    }
}

public enum ProtectionReason: String, Equatable {
    case manual, headTurn, extraFace, ownerUnverified, sensitiveText, appEvent, windowTitle, warningEscalated, pauseRule
}
public struct ActiveProtectionRule: Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let reason: ProtectionReason
    public init(id: UUID, name: String, reason: ProtectionReason) { self.id = id; self.name = name; self.reason = reason }
}
public struct ProtectionWarning: Equatable, Identifiable {
    public let rule: ActiveProtectionRule
    public let secondsRemaining: Int
    public let sound: Bool
    public var id: UUID { rule.id }
    public init(rule: ActiveProtectionRule, secondsRemaining: Int, sound: Bool) {
        self.rule = rule; self.secondsRemaining = secondsRemaining; self.sound = sound
    }
}
public struct ProtectionRegion: Equatable {
    public let rectangle: CGRect
    public let blur: BlurParameters
    public let ruleID: UUID
    public init(rectangle: CGRect, blur: BlurParameters, ruleID: UUID) {
        self.rectangle = rectangle; self.blur = blur; self.ruleID = ruleID
    }
}
public struct DisplayProtectionPlan: Equatable {
    public let displayID: UInt32
    public var fullScreenCoverage: Double = 0
    public var blur = BlurParameters()
    public var direction: ShieldDirection = .left
    public var animatesCoverage = true
    public var regions: [ProtectionRegion] = []
    public var textRegions: [ProtectionRegion] = []
    public var excludedRegions: [CGRect] = []
    public var activeRules: [ActiveProtectionRule] = []
    public var hasProtection: Bool { fullScreenCoverage > 0 || !regions.isEmpty || !textRegions.isEmpty }
    public var orderedRegions: [ProtectionRegion] {
        var order: [UUID: Int] = [:]
        for (index, rule) in activeRules.enumerated() where order[rule.id] == nil { order[rule.id] = index }
        return (regions + textRegions).sorted { (order[$0.ruleID] ?? Int.max) < (order[$1.ruleID] ?? Int.max) }
    }
}
public enum ProtectionEngineState: Equatable { case running, paused(until: TimeInterval?), cleared, suspended }
public struct ProtectionPlan: Equatable {
    public let displays: [DisplayProtectionPlan]
    public let activeRules: [ActiveProtectionRule]
    public let warnings: [ProtectionWarning]
    public let state: ProtectionEngineState
    public var textAnalysisRuleIDs: [UUID] = []
    public var captureDisplayIDs: [UInt32] = []
    public var hasProtection: Bool { displays.contains(where: \.hasProtection) }
}

/// All inputs use this bus. Samples contain geometry/decisions, never frames or OCR strings.
public enum ProtectionEvent {
    case displays([ProtectionDisplay])
    case windows([ProtectionWindow], activeWindow: CGRect?, activeBundleID: String?, controlRegions: [CGRect] = [])
    case permission(PermissionKind, granted: Bool)
    case escapeAvailability(Bool)
    case manual(UUID, active: Bool)
    case peek(UUID, held: Bool)
    case headCoverage(HeadTrackingSource, coverage: Double, displays: [UInt32: Double], calibrated: Bool, direction: ShieldDirection = .left)
    case headRuleCoverage(UUID, coverage: Double, displays: [UInt32: Double], calibrated: Bool, direction: ShieldDirection = .left)
    case nearby(NearbyDetection, active: Bool, ownerVerified: Bool)
    case nearbyMonitoring(NearbyDetection, Bool)
    case detectedText(UUID, regions: [UInt32: [CGRect]])
    case blurNow(UUID)
    case pause(until: TimeInterval?)
    case resume
    case escape
    case suspend
    case wake
    case tick
}

/// A value type with a deterministic clock. No timers, capture, rendering, persistence, or UI.
public struct ProtectionEngine {
    public private(set) var rules: [ProtectionRule]
    public var defaultBlur: BlurParameters
    public private(set) var state: ProtectionEngineState = .running
    private var displays: [ProtectionDisplay] = []
    private var windows: [ProtectionWindow] = []
    private var activeWindow: CGRect?
    private var controlRegions: [CGRect] = []
    private var activeBundleID: String?
    private var permissions = Set<PermissionKind>()
    private var escapeAvailable = false
    private var manual = Set<UUID>()
    private var peeking = Set<UUID>()
    private var rememberedMatches: [UUID: Set<String>] = [:]
    private struct HeadSample { let coverage: Double; let displays: [UInt32: Double]; let calibrated: Bool; let direction: ShieldDirection }
    private var head: [HeadTrackingSource: HeadSample] = [:]
    private var ruleHead: [UUID: HeadSample] = [:]
    private struct NearbySample { let active: Bool; let ownerVerified: Bool }
    private var nearby: [NearbyDetection: NearbySample] = [:]
    private var nearbyMonitoring: [NearbyDetection: Bool] = [:]
    private var text: [UUID: [UInt32: [CGRect]]] = [:]
    private var warningStarts: [UUID: TimeInterval] = [:]
    private var escalated = Set<UUID>()
    private var suppressed = Set<UUID>()
    private var pauseStarts: [UUID: TimeInterval] = [:]
    private var beforeSuspend: ProtectionEngineState = .running

    public init(rules: [ProtectionRule] = [], defaultBlur: BlurParameters = BlurParameters()) throws {
        try Self.validate(rules)
        self.rules = rules; self.defaultBlur = defaultBlur
    }
    public mutating func replaceRules(_ rules: [ProtectionRule]) throws {
        try Self.validate(rules)
        let previous = Dictionary(uniqueKeysWithValues: self.rules.map { ($0.id, $0.scope) })
        rememberedMatches = rememberedMatches.filter { id, _ in rules.contains { $0.id == id && $0.scope == previous[id] && $0.isEnabled } }
        self.rules = rules
        let ids = Set(rules.filter(\.isEnabled).map(\.id))
        let manualIDs = Set(rules.filter { rule in if case .manual = rule.trigger { return rule.isEnabled }; return false }.map(\.id))
        let peekIDs = Set(rules.filter { rule in
            guard manualIDs.contains(rule.id) else { return false }
            if case .blur(_, .some) = rule.action { return true }; return false
        }.map(\.id))
        manual.formIntersection(manualIDs); peeking.formIntersection(peekIDs); escalated.formIntersection(ids); suppressed.formIntersection(ids)
        warningStarts = warningStarts.filter { ids.contains($0.key) }
        pauseStarts = pauseStarts.filter { ids.contains($0.key) }
        text = text.filter { ids.contains($0.key) }
        ruleHead = ruleHead.filter { ids.contains($0.key) }
    }
    public func isManuallyActivated(_ id: UUID) -> Bool { manual.contains(id) }
    public func isPeeking(_ id: UUID) -> Bool { peeking.contains(id) }
    private static func validate(_ rules: [ProtectionRule]) throws {
        guard Set(rules.map(\.id)).count == rules.count else { throw ProtectionEngineError.duplicateRuleID }
        for rule in rules {
            let errors = ProtectionRuleValidator.validate(rule)
            if !errors.isEmpty { throw ProtectionEngineError.invalidRule(rule.id, errors) }
        }
    }

    @discardableResult public mutating func send(_ event: ProtectionEvent, at time: TimeInterval, date: Date = Date(),
                                                calendar: Calendar = .current) -> ProtectionPlan {
        switch event {
        case .displays(let values): displays = values
        case .windows(let values, let active, let bundle, let controls):
            windows = values; activeWindow = active; activeBundleID = bundle; controlRegions = controls
            restoreRememberedManualRegions()
        case .permission(let kind, let granted): if granted { permissions.insert(kind) } else { permissions.remove(kind) }
        case .escapeAvailability(let value): escapeAvailable = value
        case .manual(let id, let active):
            if rules.contains(where: { rule in
                guard rule.id == id && rule.isEnabled else { return false }
                if case .manual = rule.trigger { return true }; return false
            }) {
                if active { manual.insert(id); suppressed.remove(id) } else { manual.remove(id); peeking.remove(id) }
            }
        case .peek(let id, let held): if held { peeking.insert(id) } else { peeking.remove(id) }
        case .headCoverage(let source, let coverage, let values, let calibrated, let direction):
            head[source] = HeadSample(coverage: Self.coverage(coverage), displays: values.mapValues(Self.coverage), calibrated: calibrated, direction: direction)
        case .headRuleCoverage(let id, let coverage, let values, let calibrated, let direction):
            if rules.contains(where: { rule in if case .headTurn = rule.trigger { return rule.id == id }; return false }) {
                ruleHead[id] = HeadSample(coverage: Self.coverage(coverage), displays: values.mapValues(Self.coverage), calibrated: calibrated, direction: direction)
            }
        case .nearby(let detection, let active, let verified): nearby[detection] = NearbySample(active: active, ownerVerified: verified)
        case .nearbyMonitoring(let detection, let monitoring): nearbyMonitoring[detection] = monitoring
        case .detectedText(let id, let regions): text[id] = regions
        case .blurNow(let id): if warningStarts[id] != nil { escalated.insert(id) }
        case .pause(let until):
            if state == .suspended { beforeSuspend = .paused(until: until) } else { state = .paused(until: until) }
            peeking = []
        case .resume:
            if state == .suspended { beforeSuspend = .running } else { state = .running }
            suppressed = []
            for (id, matches) in rememberedMatches where !matches.isEmpty { manual.insert(id) }
        case .escape:
            if state == .suspended { beforeSuspend = .cleared } else { state = .cleared }
            manual = []; peeking = []; warningStarts = [:]; escalated = []; pauseStarts = [:]
            suppressed = Set(rules.map(\.id))
        case .suspend: if state != .suspended { beforeSuspend = state }; state = .suspended; peeking = []
        case .wake: if state == .suspended { state = beforeSuspend }
        case .tick: break
        }
        return evaluate(at: time, date: date, calendar: calendar)
    }

    private mutating func restoreRememberedManualRegions() {
        for rule in rules where rule.isEnabled {
            guard case .manual = rule.trigger, case .region(let ref, _, .rememberWindowTitle) = rule.scope else { continue }
            let matches = Set(windows.filter { $0.matches(ref) }.map { "\($0.reference.ownerPID ?? 0):\($0.reference.windowID ?? 0)" })
            let previous = rememberedMatches[rule.id] ?? []
            if !matches.subtracting(previous).isEmpty && !suppressed.contains(rule.id) { manual.insert(rule.id) }
            if matches.isEmpty { manual.remove(rule.id); peeking.remove(rule.id) }
            rememberedMatches[rule.id] = matches
        }
    }

    private static func coverage(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
    private func guardsPass(_ rule: ProtectionRule, date: Date, calendar: Calendar) -> Bool {
        rule.guards.allSatisfy { condition in
            switch condition {
            case .permission(let kind):
                // Losing camera access cannot authorize revealing an owner-guarded
                // scope. Screen permission and Escape still gate actual output.
                if kind == .camera {
                    if rule.guards.contains(.ownerVerification), case .extraFace = rule.trigger { return true }
                    if case .headTurn(.camera) = rule.trigger, (ruleHead[rule.id] ?? head[.camera])?.calibrated == true { return true }
                }
                return permissions.contains(kind)
            case .calibrationRequired:
                if case .headTurn(let source) = rule.trigger { return (ruleHead[rule.id] ?? head[source])?.calibrated == true }; return false
            // Verification gates uncovering, not covering. Unknown identity must fail closed.
            case .ownerVerification: return true
            case .appCondition(let bundle): return activeBundleID == bundle
            case .notPaused: return state == .running || state == .cleared
            case .timeWindow(let start, let end):
                guard let a = ProtectionRuleValidator.minutes(start), let b = ProtectionRuleValidator.minutes(end) else { return false }
                let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                return a == b || (a < b ? (a..<b).contains(now) : now >= a || now < b)
            }
        }
    }
    private func triggerActive(_ rule: ProtectionRule) -> Bool {
        switch rule.trigger {
        case .manual: return manual.contains(rule.id)
        case .headTurn(let source): return ((ruleHead[rule.id] ?? head[source])?.coverage ?? 0) > 0 || (ruleHead[rule.id] ?? head[source])?.displays.values.contains(where: { $0 > 0 }) == true
        case .extraFace(let detection):
            guard let sample = nearby[detection] else { return false }
            return sample.active || (rule.guards.contains(.ownerVerification) && !sample.ownerVerified)
        case .sensitiveText: return text[rule.id]?.values.contains(where: { !$0.isEmpty }) == true
        case .appEvent(let bundle, let event):
            return event == .activated ? activeBundleID == bundle : windows.contains { $0.reference.bundleID == bundle }
        case .windowTitle(let bundle, let digest): return windows.contains { $0.reference.bundleID == bundle && $0.reference.titleDigest == digest }
        }
    }
    private func reason(_ rule: ProtectionRule) -> ProtectionReason {
        if escalated.contains(rule.id) { return .warningEscalated }
        switch rule.trigger {
        case .manual: return .manual
        case .headTurn: return .headTurn
        case .extraFace(let detection): return rule.guards.contains(.ownerVerification) && nearby[detection]?.ownerVerified != true ? .ownerUnverified : .extraFace
        case .sensitiveText: return .sensitiveText
        case .appEvent: return .appEvent
        case .windowTitle: return .windowTitle
        }
    }
    private func ordered(_ a: ProtectionRule, _ b: ProtectionRule) -> Bool {
        func rank(_ rule: ProtectionRule) -> Int {
            if case .pauseOtherProtection = rule.action { return 4 }
            switch rule.scope {
            case .allDisplays, .display: return 3
            case .allDisplaysExceptActiveWindow: return 2
            default: return 1
            }
        }
        if rank(a) != rank(b) { return rank(a) > rank(b) }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    private mutating func evaluate(at time: TimeInterval, date: Date, calendar: Calendar) -> ProtectionPlan {
        if case .paused(let deadline) = state, let deadline, time >= deadline { state = .running }
        var eligible: [ProtectionRule] = []
        for rule in rules where rule.isEnabled {
            let active = triggerActive(rule)
            if !active {
                // Legacy AirPods protection rearms after facing center. Escape keeps
                // OCR, saved/app regions, and camera rules cleared until explicit resume.
                if case .headTurn(.airPods) = rule.trigger { suppressed.remove(rule.id) }
                warningStarts.removeValue(forKey: rule.id); escalated.remove(rule.id); pauseStarts.removeValue(forKey: rule.id)
            }
            if active && !suppressed.contains(rule.id) && guardsPass(rule, date: date, calendar: calendar) { eligible.append(rule) }
        }
        var plans = displays.map { DisplayProtectionPlan(displayID: $0.id) }
        guard state != .suspended, { if case .paused = state { return false }; return true }() else {
            return ProtectionPlan(displays: plans, activeRules: [], warnings: [], state: state)
        }
        eligible.sort(by: ordered)
        if state == .cleared && !eligible.isEmpty { state = .running }
        let pauseRules = eligible.filter { if case .pauseOtherProtection = $0.action { return true }; return false }
        let pausing = pauseRules.filter { rule in
            if pauseStarts[rule.id] == nil { pauseStarts[rule.id] = time }
            if case .pauseOtherProtection(let duration, _) = rule.action, let duration { return time - (pauseStarts[rule.id] ?? time) < duration }
            return true
        }
        if pausing.contains(where: { if case .pauseOtherProtection(_, .all) = $0.action { return true }; return false }) {
            return ProtectionPlan(displays: plans, activeRules: pausing.map { ActiveProtectionRule(id: $0.id, name: $0.name, reason: .pauseRule) }, warnings: [], state: state)
        }
        let focus = eligible.contains { rule in
            guard case .blur(_, let peek) = rule.action else { return false }
            if peek != nil && peeking.contains(rule.id) && manual.contains(rule.id) { return false }
            if case .allDisplaysExceptActiveWindow = rule.scope { return true }; return false
        }
        if focus || !pausing.isEmpty { eligible.removeAll { if case .headTurn = $0.trigger { return true }; return false } }
        var warnings: [ProtectionWarning] = []
        var activeRules = pausing.map { ActiveProtectionRule(id: $0.id, name: $0.name, reason: .pauseRule) }
        for rule in eligible {
            let status = ActiveProtectionRule(id: rule.id, name: rule.name, reason: reason(rule))
            let parameters: BlurParameters
            switch rule.action {
            case .blur(let blur, let peek):
                parameters = blur
                if peek != nil && peeking.contains(rule.id) && manual.contains(rule.id) { continue }
            case .warnThenBlur(let delay, let sound), .warnOnly(let delay, let sound):
                if warningStarts[rule.id] == nil { warningStarts[rule.id] = time }
                let remaining = max(0, delay - max(0, time - (warningStarts[rule.id] ?? time)))
                if case .warnThenBlur = rule.action, remaining <= 0 { escalated.insert(rule.id) }
                if !escalated.contains(rule.id) {
                    warnings.append(ProtectionWarning(rule: status, secondsRemaining: Int(ceil(remaining)), sound: sound))
                    activeRules.append(status); continue
                }
                parameters = defaultBlur
            case .pauseOtherProtection: continue
            }
            // A usable Escape route is required before any output can cover a display.
            guard escapeAvailable && permissions.contains(.screen) else { continue }
            var contributed = false
            for index in plans.indices {
                var displayContributed = false
                let display = displays[index]
                var coverage = 1.0
                if case .headTurn(let source) = rule.trigger { coverage = (ruleHead[rule.id] ?? head[source])?.displays[display.id] ?? (ruleHead[rule.id] ?? head[source])?.coverage ?? 0 }
                let region: (CGRect) -> ProtectionRegion = { ProtectionRegion(rectangle: $0, blur: parameters, ruleID: rule.id) }
                switch rule.scope {
                case .allDisplays, .display:
                    if case .display(let ids) = rule.scope, !ids.contains(display.id) { continue }
                    if coverage > 0 {
                        if case .headTurn = rule.trigger {} else { plans[index].animatesCoverage = false }
                        if plans[index].fullScreenCoverage == 0 {
                            plans[index].blur = parameters
                            if case .headTurn(let source) = rule.trigger { plans[index].direction = (ruleHead[rule.id] ?? head[source])?.direction ?? .left }
                        }
                        plans[index].fullScreenCoverage = max(plans[index].fullScreenCoverage, coverage)
                        displayContributed = true
                    }
                case .allDisplaysExceptActiveWindow:
                    let exclusions = controlRegions + (activeWindow.map { [$0] } ?? [])
                    let rectangles = ScreenRegions.visible(display.frame, behind: exclusions)
                    plans[index].regions += rectangles.map(region)
                    plans[index].excludedRegions = exclusions.map { $0.intersection(display.frame) }.filter(Self.validRectangle)
                    displayContributed = !rectangles.isEmpty
                case .window(let ref), .region(let ref, _, _):
                    // Window regions follow matching windows; display regions below stay fixed to their display.
                    for window in windows where window.matches(ref) {
                        let rectangle: CGRect
                        if case .region(_, let normalized, _) = rule.scope { rectangle = ScreenRegions.fromVision(normalized, in: window.frame) }
                        else { rectangle = window.frame }
                        let rectangles = ScreenRegions.visible(rectangle, behind: window.occluders).map { $0.intersection(display.frame) }.filter(Self.validRectangle)
                        plans[index].regions += rectangles.map(region)
                        displayContributed = displayContributed || !rectangles.isEmpty
                    }
                case .detectedText:
                    let rectangles = (text[rule.id]?[display.id] ?? []).flatMap { ScreenRegions.visible($0, behind: controlRegions) }
                        .map { $0.intersection(display.frame) }.filter(Self.validRectangle)
                    plans[index].textRegions += rectangles.map(region)
                    displayContributed = !rectangles.isEmpty
                case .displayRegion(let id, let normalized):
                    guard display.id == id else { continue }
                    let rectangle = ScreenRegions.fromVision(normalized, in: display.frame)
                    let rectangles = ScreenRegions.visible(rectangle, behind: controlRegions)
                        .map { $0.intersection(display.frame) }.filter(Self.validRectangle)
                    plans[index].regions += rectangles.map(region)
                    displayContributed = !rectangles.isEmpty
                }
                if displayContributed { plans[index].activeRules.append(ActiveProtectionRule(id: rule.id, name: rule.name, reason: reason(rule))) }
                contributed = contributed || displayContributed
            }
            if contributed { activeRules.append(ActiveProtectionRule(id: rule.id, name: rule.name, reason: reason(rule))) }
        }
        let textAnalysisRuleIDs = escapeAvailable && permissions.contains(.screen) ? rules.filter { rule in
            guard rule.isEnabled, !suppressed.contains(rule.id), guardsPass(rule, date: date, calendar: calendar) else { return false }
            if case .sensitiveText = rule.trigger { return true }; return false
        }.map(\.id) : []
        var captureIDs = Set<UInt32>()
        for rule in rules.sorted(by: ordered) where rule.isEnabled && !suppressed.contains(rule.id) && guardsPass(rule, date: date, calendar: calendar) {
            guard case .extraFace(let detection) = rule.trigger, nearbyMonitoring[detection] == true,
                  case .blur(let parameters, _) = rule.action, escapeAvailable, permissions.contains(.screen) else { continue }
            for index in plans.indices {
                let display = displays[index]
                let matches: Bool
                if case .displayRegion(let id, _) = rule.scope { matches = display.id == id }
                else if case .window(let ref) = rule.scope { matches = windows.contains { $0.matches(ref) && $0.frame.intersects(display.frame) } }
                else { matches = true }
                if matches {
                    if !plans[index].hasProtection && !captureIDs.contains(display.id) { plans[index].blur = parameters }
                    captureIDs.insert(display.id)
                }
            }
        }
        return ProtectionPlan(displays: plans, activeRules: activeRules, warnings: warnings, state: state,
                              textAnalysisRuleIDs: textAnalysisRuleIDs, captureDisplayIDs: displays.map(\.id).filter { captureIDs.contains($0) })
    }
    private static func validRectangle(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}

public enum ProtectionEngineError: Error, Equatable {
    case duplicateRuleID
    case invalidRule(UUID, [RuleValidationError])
}
