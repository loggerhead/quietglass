import AppKit
import CryptoKit
import ShieldCore

/// Window and application events plus manual selection. No capture or product switches.
@MainActor
final class RuleEventSources {
    let coordinator: ProtectionCoordinator
    var onChange: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var onRetryCapture: (() -> Void)?
    private(set) var frontBundleID: String?
    private(set) var frontPID: pid_t?
    private(set) var frontAppName = "No active app"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    init(coordinator: ProtectionCoordinator) { self.coordinator = coordinator }
    var rules: [ProtectionRule] { coordinator.document.rules }
    func start() {
        guard timer == nil else { onRetryCapture?(); refresh(); return }
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.needsGeometryPolling == true { self?.refresh() } }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }
    private var needsGeometryPolling: Bool {
        guard coordinator.plan.state == .running else { return false }
        return rules.contains { rule in
            guard rule.isEnabled else { return false }
            if case .manual = rule.trigger, !coordinator.isManuallyActivated(rule.id) {
                if case .region(_, _, .rememberWindowTitle) = rule.scope {} else { return false }
            }
            switch rule.scope { case .window, .region, .displayRegion, .detectedText, .allDisplaysExceptActiveWindow: return true; default: return false }
        }
    }
    func refresh() {
        if rules.contains(where: { rule in
            guard case .manual = rule.trigger else { return false }
            switch rule.scope { case .window(let ref), .region(let ref, _, .session): return ref.windowID != nil; default: return false }
        }), let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let existing = all.compactMap { item -> (UInt32, Int32)? in
                guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
                return (id, owner)
            }
            removeClosedWindows(existing: existing)
        }
        coordinator.send(contextEvents()); onChange?()
    }
    /// A read-only geometry snapshot for an atomic resume/wake event batch.
    /// This method never sends events or edits rules itself.
    func contextEvents() -> [ProtectionEvent] {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular {
            frontBundleID = app.bundleIdentifier; frontPID = app.processIdentifier
            frontAppName = app.localizedName ?? "Selected window"
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let bundles = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier, $0) } })
        if let pid = frontPID, bundles[pid] != frontBundleID { frontPID = nil; frontBundleID = nil; frontAppName = "No active app" }
        let items = PrivacyController.contentWindowItems(in: raw, bundleIdentifiers: bundles, displayFrames: NSScreen.screens.map(\.frame))
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = Self.windows(in: items, bundleIdentifiers: bundles, appPID: own, desktopTop: top)
        let active = frontPID.flatMap { PrivacyController.frontWindowItem(in: items, for: $0) }
            .flatMap { $0[kCGWindowBounds as String] as? NSDictionary }.flatMap { CGRect(dictionaryRepresentation: $0) }
            .map { CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height) }
        let controls = PrivacyController.visibleControlRegions(in: items, appPID: own, desktopTop: top)
        let displays = NSScreen.screens.compactMap { screen -> ProtectionDisplay? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ProtectionDisplay(id: id, frame: screen.frame)
        }
        return [.displays(displays), .windows(windows, activeWindow: active, activeBundleID: frontBundleID, controlRegions: controls)]
    }
    static func titleDigest(_ title: String) -> String {
        SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func removeClosedWindows(existing: [(UInt32, Int32)]) {
        let closed = rules.filter { rule in
            guard case .manual = rule.trigger else { return false }
            let ref: ProtectedWindowRef
            switch rule.scope { case .window(let window), .region(let window, _, .session): ref = window; default: return false }
            guard let id = ref.windowID, let owner = ref.ownerPID else { return false }
            return !existing.contains { $0.0 == id && $0.1 == owner }
        }
        guard !closed.isEmpty else { return }
        remove { candidate in closed.contains { $0.id == candidate.id } }
    }
    static func windows(in items: [[String: Any]], bundleIdentifiers: [pid_t: String], appPID: pid_t, desktopTop: CGFloat) -> [ProtectionWindow] {
        var windows: [ProtectionWindow] = [], occluders: [CGRect] = []
        for item in items {
            guard let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary, let quartz = CGRect(dictionaryRepresentation: bounds) else { continue }
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            if owner == appPID && layer != 0 { continue }
            let frame = CGRect(x: quartz.minX, y: desktopTop - quartz.maxY, width: quartz.width, height: quartz.height)
            if owner != appPID, layer == 0, let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let bundle = bundleIdentifiers[owner] {
                let title = item[kCGWindowName as String] as? String
                windows.append(ProtectionWindow(reference: ProtectedWindowRef(bundleID: bundle, windowID: id, ownerPID: owner,
                    titleDigest: title.flatMap { $0.isEmpty ? nil : Self.titleDigest($0) }), frame: frame, occluders: occluders))
            }
            if layer >= 0 { occluders.append(frame) }
        }
        return windows
    }
    func manualRule(scope: ProtectionScope) -> ProtectionRule? {
        rules.first { if case .manual = $0.trigger { return $0.scope == scope }; return false }
    }
    func setManual(scope: ProtectionScope, active: Bool? = nil) {
        if scope == .allDisplaysExceptActiveWindow, timer != nil { refresh() }
        perform {
            var rule = manualRule(scope: scope) ?? ProtectionRule(name: scope == .allDisplays ? "Blur screen now" : "Focus", trigger: .manual(shortcut: nil), scope: scope,
                action: .blur(coordinator.document.preferences.defaultBlur, peek: nil), guards: [.permission(.screen)])
            if !rule.isEnabled || !rules.contains(where: { $0.id == rule.id }) { rule.isEnabled = true; try replace(rule) }
            coordinator.send(.manual(rule.id, active: active ?? !coordinator.isManuallyActivated(rule.id)))
            onChange?()
        }
    }
    func setPeek(_ held: Bool) {
        coordinator.send(rules.compactMap { rule -> ProtectionEvent? in
            guard case .manual = rule.trigger, case .blur(_, .some) = rule.action else { return nil }
            return .peek(rule.id, held: held)
        }); onChange?()
    }
    func protect(_ window: ProtectedWindow, rectangle: CGRect? = nil, recipeID: UUID? = nil) {
        guard let app = NSRunningApplication(processIdentifier: window.owner), let bundle = app.bundleIdentifier else { return }
        protect(reference: ProtectedWindowRef(bundleID: bundle, windowID: window.id, ownerPID: window.owner), name: app.localizedName ?? window.name, rectangle: rectangle, recipeID: recipeID)
        refresh()
    }
    func protect(reference ref: ProtectedWindowRef, name: String, rectangle: CGRect? = nil, recipeID: UUID? = nil) {
        perform {
            let scope: ProtectionScope = rectangle.map { .region(ref, normalizedRect: $0, persistence: .session) } ?? .window(ref)
            let recipe = rules.first { rule in
                guard case .manual = rule.trigger, recipeID == nil || (rule.id == recipeID && rule.isEnabled) else { return false }
                if rectangle == nil, case .window(let ref) = rule.scope { return ref.bundleID == "$selection" }
                if rectangle != nil, case .region(let ref, _, _) = rule.scope { return ref.bundleID == "$selection" }
                return false
            }
            if recipeID != nil && recipe == nil { onNotice?("This rule is unavailable. Choose an enabled rule and try again."); return }
            let rule = ProtectionRule(name: name, priority: recipe?.priority ?? 0, trigger: .manual(shortcut: nil), scope: scope,
                action: recipe?.action ?? .blur(coordinator.document.preferences.defaultBlur, peek: nil), guards: recipe?.guards ?? [.permission(.screen)])
            try replace(rule); coordinator.send(.manual(rule.id, active: true)); onChange?()
        }
    }
    func remember(_ id: UUID) {
        perform {
            guard var rule = rules.first(where: { $0.id == id }), case .region(var ref, let rectangle, _) = rule.scope, let windowID = ref.windowID else { return }
            let items = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let title = items.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ref.ownerPID })?[kCGWindowName as String] as? String, !title.isEmpty else {
                onNotice?("This window has no readable title. Keep the area selected for this session instead."); return
            }
            ref.titleDigest = Self.titleDigest(title); ref.windowID = nil; ref.ownerPID = nil
            rule.trigger = .windowTitle(bundleID: ref.bundleID, titleDigest: ref.titleDigest!)
            rule.scope = .region(ref, normalizedRect: rectangle, persistence: .rememberWindowTitle)
            try replace(rule); refresh()
        }
    }
    func setSensitive(enabled: Bool? = nil, options: SensitiveTextOptions? = nil, phrases: [String]? = nil) {
        perform {
            var rule = rules.first { if case .sensitiveText = $0.trigger { return true }; return false } ?? ProtectionPreset.sensitiveText.rule(parameters: coordinator.document.preferences.defaultBlur)
            if let enabled { rule.isEnabled = enabled }
            if case .sensitiveText(let existingTypes, let existingPhrases) = rule.trigger {
                let types = options.map { options in Set(SensitiveTextType.allCases.filter { options.contains($0.option) }) } ?? existingTypes
                rule.trigger = .sensitiveText(types: types, phrases: phrases.map(SensitiveText.cleanPhrases) ?? existingPhrases)
            }
            try replace(rule)
        }
    }
    func remove(_ predicate: (ProtectionRule) -> Bool) { perform { try coordinator.saveRules(rules.filter { !predicate($0) }); onChange?() } }
    func replace(_ rule: ProtectionRule) throws {
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index] = rule } else { updated.append(rule) }
        try coordinator.saveRules(updated); onChange?()
    }
    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { onNotice?("Protection rules could not be saved. Your previous rules are still in use."); onChange?() }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
    }
}
