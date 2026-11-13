//  Created by Clinton Imaro on 20/09/2026.

import AppKit
import ScreenCaptureKit
import ShieldCore

struct ProtectedWindow: Equatable {
    let id: CGWindowID
    let owner: pid_t
    let name: String
}

struct ProtectedArea: Identifiable, Equatable {
    let id: UUID
    let window: ProtectedWindow
    let rectangle: CGRect
    init(id: UUID = UUID(), window: ProtectedWindow, rectangle: CGRect) { self.id = id; self.window = window; self.rectangle = rectangle }
}

/// Selection and read-only presentation of the rule document and current plan.
/// Capture, OCR, conflict state, and rendering belong to the coordinator/executor.
@MainActor
final class PrivacyController: NSObject, ObservableObject, SCContentSharingPickerObserver {
    private(set) var ruleSources: RuleEventSources?
    private let demonstrationRuleID = UUID()
    private let areaSelector = AreaSelectionController()
    private var areaSelectionTask: Task<Void, Never>?
    private var selectionRecipeID: UUID?
    var onPrepareAreaSelection: (() -> Void)?
    @Published private(set) var notice: String?
    @Published private(set) var captureUnavailable = false
    @Published private(set) var ready = false
    private var coordinator: ProtectionCoordinator? { ruleSources?.coordinator }
    var instant: Bool { ruleSources?.manualRule(scope: .allDisplays).map { coordinator?.isManuallyActivated($0.id) == true } ?? false }
    var peeking: Bool { ruleSources?.manualRule(scope: .allDisplays).map { coordinator?.isPeeking($0.id) == true } ?? false }
    var paused: Bool { coordinator?.plan.state != .running }
    var focusEnabled: Bool { ruleSources?.manualRule(scope: .allDisplaysExceptActiveWindow).map { coordinator?.isManuallyActivated($0.id) == true } ?? false }
    var fullScreen: Bool { coordinator?.plan.displays.contains { $0.fullScreenCoverage > 0 } == true }
    var wantsProtection: Bool { coordinator?.requiresEscape == true }
    var nearbyMonitoring: Bool { ruleSources?.rules.contains { rule in if case .extraFace = rule.trigger { return rule.isEnabled }; return false } == true }
    var nearbyCovered: Bool {
        let ids = Set(ruleSources?.rules.filter { if case .extraFace = $0.trigger { return true }; return false }.map(\.id) ?? [])
        return coordinator?.plan.displays.contains { $0.hasProtection && $0.activeRules.contains { ids.contains($0.id) } } == true
    }
    var testCovered: Bool { coordinator?.isManuallyActivated(demonstrationRuleID) == true }
    var frontPID: pid_t? { ruleSources?.frontPID }
    var frontBundleID: String? { ruleSources?.frontBundleID }
    var frontAppName: String { ruleSources?.frontAppName ?? "No active app" }
    var displayNames: [String] { NSScreen.screens.map(\.localizedName) }
    var detectedCount: Int { coordinator?.plan.displays.reduce(0) { $0 + $1.textRegions.count } ?? 0 }
    var protectedAreas: [ProtectedArea] {
        (ruleSources?.rules ?? []).compactMap { rule in
            guard case .manual = rule.trigger, case .region(let ref, let rectangle, .session) = rule.scope,
                  let id = ref.windowID, let pid = ref.ownerPID else { return nil }
            return ProtectedArea(id: rule.id, window: ProtectedWindow(id: id, owner: pid, name: rule.name), rectangle: rectangle)
        }
    }
    var selectedWindow: ProtectedWindow? {
        (ruleSources?.rules ?? []).compactMap { rule in
            guard case .manual = rule.trigger, case .window(let ref) = rule.scope, let id = ref.windowID, let pid = ref.ownerPID else { return nil }
            return ProtectedWindow(id: id, owner: pid, name: rule.name)
        }.first
    }
    var savedAreas: [SavedWindowArea] {
        (ruleSources?.rules ?? []).compactMap { rule in
            guard case .windowTitle(let bundle, let digest) = rule.trigger, case .region(_, let rect, _) = rule.scope else { return nil }
            return SavedWindowArea(id: rule.id, bundleID: bundle, appName: rule.name, titleDigest: digest, rectangle: rect)
        }
    }
    private var textRule: ProtectionRule? { ruleSources?.rules.first { if case .sensitiveText = $0.trigger { return true }; return false } }
    var customPhrases: [String] { if case .sensitiveText(_, let phrases) = textRule?.trigger { return phrases }; return [] }
    var scanEnabled: Bool {
        get { textRule?.isEnabled == true }
        set { ruleSources?.setSensitive(enabled: newValue) }
    }
    var scanOptions: SensitiveTextOptions {
        get { if case .sensitiveText(let types, _) = textRule?.trigger { return types.reduce(SensitiveTextOptions()) { $0.union($1.option) } }; return [] }
        set { ruleSources?.setSensitive(options: newValue) }
    }
    var canPickWindow: Bool { if #available(macOS 15.2, *) { return true }; return false }
    override init() { super.init(); SCContentSharingPicker.shared.add(self) }
    func attachRules(_ sources: RuleEventSources) {
        ruleSources = sources
        sources.onNotice = { [weak self] in self?.notice = $0 }
        sources.onChange = { [weak self] in self?.projectRules() }
        projectRules()
    }
    func projectRules() { objectWillChange.send() }
    func ruleCaptureReady() { ready = true; captureUnavailable = false; notice = nil }
    func ruleCaptureFailed(_ error: Error) { captureUnavailable = true; ready = false; notice = "Screen access is unavailable. Open Screen Settings to restore it." }
    func ruleTextFailed() { notice = "Text detection is temporarily unavailable. Try pausing and resuming protection." }
    func setFocus(_ value: Bool) { ruleSources?.setManual(scope: .allDisplaysExceptActiveWindow, active: value) }
    func setTestCovered(_ value: Bool) { coordinator?.setTransient(demonstrationRuleID, name: "Protection test", active: value) }
    func savePhrases(_ text: String) { ruleSources?.setSensitive(phrases: text.components(separatedBy: .newlines)) }
    func start() { ruleSources?.start() }
    func rememberArea(_ area: ProtectedArea) { ruleSources?.remember(area.id) }
    func toggleInstant() { ruleSources?.setManual(scope: .allDisplays) }
    func setPeeking(_ value: Bool) { ruleSources?.setPeek(value) }
    func dismissAll() {
        areaSelectionTask?.cancel(); areaSelector.close(); coordinator?.clear()
        ruleSources?.remove { rule in
            if case .manual = rule.trigger, case .region(let ref, _, .session) = rule.scope { return ref.windowID != nil }; return false
        }
    }
    func resume() { coordinator?.resume() }
    func pauseProtection() { coordinator?.pause() }
    func removeWindow() { ruleSources?.remove { if case .manual = $0.trigger, case .window = $0.scope { return true }; return false } }
    func chooseArea(recipeID: UUID? = nil) {
        areaSelectionTask?.cancel()
        areaSelector.close(); SCContentSharingPicker.shared.isActive = false
        selectionRecipeID = recipeID
        guard let pid = frontPID, let app = NSRunningApplication(processIdentifier: pid) else {
            notice = "Open the window you want to protect, then choose an area."
            return
        }
        notice = nil
        NSApp.yieldActivation(to: app)
        onPrepareAreaSelection?()
        app.activate(from: .current, options: [])
        areaSelectionTask = Task { [weak self] in
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                   let item = Self.frontWindowItem(in: self.windowList(onScreen: true), for: pid) {
                    self.showAreaSelector(item: item, pid: pid, name: app.localizedName ?? "Selected window")
                    return
                }
            }
            self?.notice = "Bring the window you want to protect into view, then choose an area again."
        }
    }

    private func showAreaSelector(item: [String: Any], pid: pid_t, name: String) {
        guard
              let number = item[kCGWindowNumber as String] as? NSNumber,
              let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let quartz = CGRect(dictionaryRepresentation: bounds) else {
            notice = "Open a window first, then choose an area."
            return
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: quartz.minX, y: top - quartz.maxY, width: quartz.width, height: quartz.height)
        let window = ProtectedWindow(id: number.uint32Value, owner: pid, name: name)
        let recipeID = selectionRecipeID
        areaSelector.show(frame: frame) { [weak self] rectangle in
            self?.ruleSources?.protect(window, rectangle: rectangle, recipeID: recipeID)
        }
    }

    func protectArea(_ rectangle: CGRect, in window: ProtectedWindow) {
        ruleSources?.protect(window, rectangle: rectangle)
    }

    func removeArea(_ id: UUID) {
        ruleSources?.remove { $0.id == id }
    }
    func removeAllAreas() {
        ruleSources?.remove { if case .manual = $0.trigger, case .region = $0.scope { return true }; return false }
    }

    func protectFrontWindow() {
        guard let pid = frontPID else { notice = "Open the window you want to protect first."; return }
        guard let item = Self.frontWindowItem(in: windowList(onScreen: true), for: pid),
              let number = item[kCGWindowNumber as String] as? NSNumber else {
            notice = QG("No visible window is available for %@.", frontAppName)
            return
        }
        select(ProtectedWindow(id: number.uint32Value, owner: pid,
                               name: item[kCGWindowName as String] as? String ?? frontAppName))
    }

    func chooseWindow(recipeID: UUID? = nil) {
        areaSelectionTask?.cancel(); areaSelector.close(); selectionRecipeID = recipeID
        guard canPickWindow else { protectFrontWindow(); return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.clinton.QuietGlass"]
        configuration.allowsChangingSelectedContent = false
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    private func select(_ window: ProtectedWindow) {
        ruleSources?.protect(window, recipeID: selectionRecipeID)
        selectionRecipeID = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in picker.isActive = false }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            picker.isActive = false
            if #available(macOS 15.2, *), let window = filter.includedWindows.first,
               let app = window.owningApplication {
                self?.select(ProtectedWindow(id: window.windowID, owner: app.processID, name: window.title ?? app.applicationName))
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            SCContentSharingPicker.shared.isActive = false
            self?.notice = "Window selection could not open. Try Protect active window instead."
        }
    }

    private func windowList(onScreen: Bool) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(onScreen ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    static func frontWindowItem(in items: [[String: Any]], for pid: pid_t) -> [String: Any]? {
        items.first { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 80, frame.height > 80 else { return false }
            return frame.height >= 200 || frame.width / frame.height < 6
        }
    }

    static func contentWindowItems(in items: [[String: Any]], bundleIdentifiers: [pid_t: String],
                                   displayFrames: [CGRect] = []) -> [[String: Any]] {
        // Desktop and cursor decorations have transparent pixels even when
        // CGWindowList reports alpha 1. Their rectangular bounds are not opaque
        // content and must not cut holes in controls or protected windows.
        // Keep other utility apps: accessory status alone does not mean transparent.
        let decorations: Set<String> = [
            "com.apple.dock",
            "com.apple.TextInputUI.xpc.CursorUIViewService",
            "com.openai.sky.CUAService"
        ]
        let desktop = displayFrames.reduce(CGRect.null) { $0.union($1) }
        let captureCanvases = displayFrames + (displayFrames.count > 1 ? [desktop] : [])
        return items.filter { item in
            guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bundle = bundleIdentifiers[pid] else { return true }
            if decorations.contains(bundle) { return false }
            // Screenshot's transparent selection/recording canvas reports
            // alpha 1 over a whole display (or the combined desktop). Keep
            // its smaller toolbar and menus as real occluders.
            guard bundle == "com.apple.screencaptureui",
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return true }
            return !captureCanvases.contains { canvas in
                abs(frame.minX - canvas.minX) <= 1 && abs(frame.minY - canvas.minY) <= 1 &&
                abs(frame.width - canvas.width) <= 1 && abs(frame.height - canvas.height) <= 1
            }
        }
    }

    static func visibleControlRegions(in items: [[String: Any]], appPID: pid_t, desktopTop: CGFloat) -> [CGRect] {
        var controls: [CGRect] = []
        var occluders: [CGRect] = []
        // CGWindowList is front-to-back. Only the visible parts of our normal
        // windows are controls; their covered bounds must not exempt other apps.
        for item in items {
            guard let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds) else { continue }
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            let frame = CGRect(x: quartz.minX, y: desktopTop - quartz.maxY, width: quartz.width, height: quartz.height)
            if owner == appPID {
                // Our blur overlays and notch must not hide Settings from this calculation.
                guard layer == 0 else { continue }
                controls += ScreenRegions.visible(frame, behind: occluders)
            }
            if layer >= 0 { occluders.append(frame) }
        }
        return controls
    }

    func screenParametersChanged() { ruleSources?.refresh() }
    func shutdown() {
        ruleSources?.shutdown(); areaSelectionTask?.cancel(); areaSelector.close()
        SCContentSharingPicker.shared.remove(self)
    }
}
