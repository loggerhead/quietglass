import AppKit
import Combine
import ShieldCore

@MainActor
protocol ProtectionPlanExecuting: AnyObject {
    func apply(_ plan: ProtectionPlan)
    func shutdown()
}

@MainActor
final class WarningPresenter: ObservableObject {
    @Published private(set) var warnings: [ProtectionWarning] = []
    private var sounds: [UUID: NearbyNoticeSound] = [:]
    private let makeSound: @MainActor () -> NearbyNoticeSound
    var visible = true { didSet { present(warnings) } }
    init(makeSound: @escaping @MainActor () -> NearbyNoticeSound = { NearbyNoticeSound() }) { self.makeSound = makeSound }
    func present(_ values: [ProtectionWarning]) {
        warnings = values
        let ids = Set(values.map(\.id))
        sounds = sounds.filter { ids.contains($0.key) }
        for warning in values {
            if sounds[warning.id] == nil { sounds[warning.id] = makeSound() }
            sounds[warning.id]?.update(needsAttention: true, visible: visible, enabled: warning.sound)
        }
    }
}

enum ProtectionCoordinatorError: Error { case shortcutConflict }

extension ProtectionRule {
    var requiredPermissions: Set<PermissionKind> {
        var values = Set(guards.compactMap { condition -> PermissionKind? in
            if case .permission(let kind) = condition { return kind }; return nil
        })
        switch trigger {
        case .headTurn(let source): values.insert(source == .camera ? .camera : .motion)
        case .extraFace: values.insert(.camera)
        case .sensitiveText: values.insert(.screen)
        default: break
        }
        switch action { case .blur, .warnThenBlur: values.insert(.screen); default: break }
        return values
    }
}

/// Owns product lifecycle. Adapters send events and consume rules; only the
/// executor below receives blur plans. Sensor algorithms remain in their adapters.
@MainActor
final class ProtectionCoordinator: ObservableObject {
    @Published private(set) var document: ProtectionDocument
    @Published private(set) var plan: ProtectionPlan
    @Published private(set) var persistenceError: Error?
    @Published private(set) var escapeAvailable = false
    let warnings: WarningPresenter
    var onRulesChanged: ((ProtectionDocument) -> Void)?
    var onRulesEnabled: (([ProtectionRule]) -> Void)?
    var onBlurPermissionNeeded: ((ProtectionRule) -> Void)?
    var onPlanChanged: ((ProtectionPlan) -> Void)?
    var refreshContext: (() -> [ProtectionEvent])?
    var prepareEscape: (() -> Bool)?
    var prepareRuleBindings: ((ProtectionDocument) -> Bool)?
    private let store: ProtectionStore
    private let executor: ProtectionPlanExecuting
    private var engine: ProtectionEngine
    private var transientRules: [UUID: ProtectionRule] = [:]
    private let clock: () -> TimeInterval
    private let wallClock: () -> Date
    private var pauseWallDeadline: Date?
    private var timer: Timer?
    private var shutdownComplete = false

    init(store: ProtectionStore, executor: ProtectionPlanExecuting, warnings: WarningPresenter? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, wallClock: @escaping () -> Date = Date.init, runsTimer: Bool = true) throws {
        self.store = store; self.executor = executor; self.clock = clock
        self.wallClock = wallClock
        self.warnings = warnings ?? WarningPresenter()
        let loaded = try store.loadOrMigrate()
        var initialEngine = try ProtectionEngine(rules: loaded.rules, defaultBlur: loaded.preferences.defaultBlur)
        let appearance = (try? PropertyListSerialization.propertyList(from: loaded.preferences.appearance, format: nil)) as? [String: Any] ?? [:]
        let monitoring = loaded.rules.contains { if case .extraFace = $0.trigger { return $0.isEnabled }; return false }
        let deadline = appearance["protectionPauseUntil"] as? Date ?? (monitoring ? appearance["nearbyPauseUntil"] as? Date : nil)
        if let deadline, deadline > wallClock() {
            let remaining = appearance["protectionPauseUntil"] == nil ? min(300, deadline.timeIntervalSince(wallClock())) : deadline.timeIntervalSince(wallClock())
            pauseWallDeadline = wallClock().addingTimeInterval(remaining)
            initialEngine.send(.pause(until: clock() + remaining), at: clock())
        } else if appearance["protectionPaused"] as? Bool == true, deadline == nil {
            initialEngine.send(.pause(until: nil), at: clock())
        }
        document = loaded
        plan = initialEngine.send(.tick, at: clock())
        engine = initialEngine
        if runsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.send(.tick) }
            }
        }
    }

    func saveRules(_ rules: [ProtectionRule]) throws {
        var updated = document; updated.rules = rules
        try save(updated)
    }
    func save(_ updated: ProtectionDocument) throws {
        let registry = ShortcutRegistry(rules: updated.rules, recenter: updated.preferences.recenterShortcut)
        guard registry.isValid else { throw ProtectionCoordinatorError.shortcutConflict }
        if let selection = updated.preferences.regionSelectionShortcut {
            let same: (ShortcutBinding) -> Bool = { $0.keyCode == selection.keyCode && $0.modifiers == selection.modifiers }
            if updated.preferences.recenterShortcut.map(same) == true || registry.bindings.contains(where: { $0.operation == .peek && same($0.binding) }) {
                throw ProtectionCoordinatorError.shortcutConflict
            }
        }
        // Validate and commit before publishing or changing the live engine.
        var replacement = engine
        try replacement.replaceRules(updated.rules + Array(transientRules.values))
        replacement.defaultBlur = updated.preferences.defaultBlur
        guard prepareRuleBindings?(updated) ?? true else { throw ProtectionCoordinatorError.shortcutConflict }
        do { try store.save(updated) }
        catch { _ = prepareRuleBindings?(document); throw error }
        let enabledRules = updated.rules.filter { rule in rule.isEnabled && document.rules.first(where: { $0.id == rule.id })?.isEnabled != true }
        document = updated; engine = replacement
        onRulesChanged?(updated)
        if !enabledRules.isEmpty { onRulesEnabled?(enabledRules) }
        send(.tick)
    }
    @discardableResult func addPreset(_ preset: ProtectionPreset) throws -> UUID {
        var updated = document
        let prototype = preset.rule(parameters: document.preferences.defaultBlur, warningDelay: document.preferences.defaultWarningDelay, warningSound: document.preferences.defaultWarningSound)
        let remembered = updated.preferences.presetRuleIDs[preset.rawValue]
        let existing = updated.rules.first { $0.id == remembered && RuleTriggerKind($0.trigger) == RuleTriggerKind(prototype.trigger) } ?? updated.rules.first {
            $0.name == prototype.name && $0.scope == prototype.scope && $0.trigger == prototype.trigger && $0.action == prototype.action && $0.guards == prototype.guards
        }
        let id: UUID
        if let existing, let index = updated.rules.firstIndex(where: { $0.id == existing.id }) {
            id = existing.id; updated.rules[index].isEnabled = true
        } else { id = prototype.id; updated.rules.append(prototype) }
        updated.preferences.presetRuleIDs[preset.rawValue] = id
        if updated != document { try save(updated) }
        return id
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        var rules = document.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        try saveRules(rules)
    }
    func remove(_ id: UUID) throws { try saveRules(document.rules.filter { $0.id != id }) }

    @discardableResult func send(_ event: ProtectionEvent) -> ProtectionPlan {
        send([event])
    }
    @discardableResult func send(_ events: [ProtectionEvent]) -> ProtectionPlan {
        guard !shutdownComplete else { return plan }
        let clears = events.contains { if case .escape = $0 { return true }; return false }
        let pauses = events.contains { if case .pause = $0 { return true }; return false }
        let resumes = events.contains { if case .resume = $0 { return true }; return false }
        let wakes = engine.state == .suspended && events.contains { if case .wake = $0 { return true }; return false }
        let uptimeExpired: Bool = { if case .paused(let until) = engine.state, let until { return clock() >= until }; return false }()
        let wallExpired = pauseWallDeadline.map { $0 <= wallClock() } ?? false
        let expires = !clears && !pauses && (uptimeExpired || wallExpired)
        // Snapshot first and submit only the final plan. Expiry while suspended
        // updates the queued user state without releasing lifecycle suspension.
        let context = !clears && (resumes || wakes || (expires && engine.state != .suspended)) ? refreshContext?() ?? [] : []
        var batch = context + events.filter { if case .escape = $0 { return false }; return true }
        if expires {
            pauseWallDeadline = nil; persistPause(active: false)
            if !resumes { batch.append(.resume) }
        }
        if clears { batch.append(.escape) }
        var value = plan
        for event in batch { value = engine.send(event, at: clock()) }
        if let prepareEscape {
            let available = prepareEscape()
            if escapeAvailable != available { escapeAvailable = available }
            value = engine.send(.escapeAvailability(available), at: clock())
        } else if batch.isEmpty { value = engine.send(.tick, at: clock()) }
        let changed = value != plan
        if changed { plan = value }
        warnings.present(value.warnings)
        executor.apply(value)
        if changed { onPlanChanged?(value) }
        return value
    }
    func toggleManual(_ id: UUID) {
        let active = engine.isManuallyActivated(id)
        send(.manual(id, active: !active))
    }
    func isManuallyActivated(_ id: UUID) -> Bool { engine.isManuallyActivated(id) }
    func isPeeking(_ id: UUID) -> Bool { engine.isPeeking(id) }
    var activeManualRuleIDs: Set<UUID> { Set((document.rules + Array(transientRules.values)).filter { engine.isManuallyActivated($0.id) }.map(\.id)) }
    var requiresEscape: Bool {
        if !activeManualRuleIDs.isEmpty { return true }
        if engine.state == .cleared || engine.state == .suspended { return false }
        return document.rules.contains { rule in
            guard rule.isEnabled else { return false }
            if case .manual = rule.trigger { return false }; return true
        }
    }
    func setTransient(_ id: UUID, name: String, scope: ProtectionScope = .allDisplays,
                      parameters: BlurParameters? = nil, active: Bool) {
        if active {
            transientRules[id] = ProtectionRule(id: id, name: name, trigger: .manual(shortcut: nil), scope: scope,
                action: .blur(parameters ?? document.preferences.defaultBlur, peek: nil), guards: [.permission(.screen)])
        } else { transientRules.removeValue(forKey: id) }
        do {
            try engine.replaceRules(document.rules + Array(transientRules.values))
            send(active ? .manual(id, active: true) : .tick)
        } catch { assertionFailure("Invalid transient protection rule: \(error)") }
    }
    func clear() { pauseWallDeadline = nil; persistPause(active: false); send(.escape) }
    func pause(seconds: TimeInterval? = nil) {
        pauseWallDeadline = seconds.map { wallClock().addingTimeInterval($0) }
        persistPause(active: true)
        send(.pause(until: seconds.map { clock() + $0 }))
    }
    func resume() { pauseWallDeadline = nil; persistPause(active: false); send(.resume) }
    private func persistPause(active: Bool) {
        var updated = document
        var values = (try? PropertyListSerialization.propertyList(from: updated.preferences.appearance, format: nil)) as? [String: Any] ?? [:]
        values.removeValue(forKey: "nearbyPauseUntil")
        values["protectionPaused"] = active
        values["protectionPauseUntil"] = pauseWallDeadline
        do {
            updated.preferences.appearance = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try store.save(updated); document = updated; persistenceError = nil
        } catch { persistenceError = error }
    }
    func suspend() { send(.suspend) }
    func wake() { send(.wake) }
    func blurNow(_ id: UUID) {
        if let rule = document.rules.first(where: { $0.id == id }) { onBlurPermissionNeeded?(rule) }
        send(.blurNow(id))
    }
    func shutdown() {
        guard !shutdownComplete else { return }
        send(.escape); shutdownComplete = true
        timer?.invalidate(); timer = nil
        warnings.present([]); executor.shutdown()
    }
}
