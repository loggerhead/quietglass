// Clinton Imaro was here 20/09/2026.

import AppKit
import Combine
import SwiftUI
import ShieldCore

@MainActor
final class PrivacySettingsController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var observation: AnyCancellable?
    private var needsInitialFrame = true
    private var fullScreen = false
    private let ruleNavigation = RuleNavigationState()
    private var layoutTimer: Timer?
    var isVisible: Bool { window.isVisible }

    init(model: AppModel) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1112, height: 828),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = QG("QuietGlass Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 620)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        let root: AnyView
        if let coordinator = model.protectionCoordinator { root = AnyView(RuleWorkspaceView(model: model, coordinator: coordinator, navigation: ruleNavigation)) }
        else { root = AnyView(Text(QG("Rules could not be loaded. Your saved preferences are unchanged. Restart to retry migration.")).padding(32)) }
        let content = NSHostingController(rootView: root)
        content.sizingOptions = []
        window.contentViewController = content
        window.delegate = self
        window.center()
        positionWindowControls()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateContentInsets() }
        }
        timer.tolerance = 0.05
        layoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        observation = model.objectWillChange.sink { [weak self, weak model] _ in
            Task { @MainActor in
                if model?.privacy.instant == true { self?.window.orderOut(nil); NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if needsInitialFrame, let bounds = window.screen?.visibleFrame {
            needsInitialFrame = false
            let size = NSSize(width: min(1112, bounds.width - 32), height: min(850, bounds.height))
            window.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
    }

    func toggleSidebar() {
        if !window.isVisible { show() }
        ruleNavigation.sidebarToggle += 1
    }

    func show(_ page: RuleWorkspacePage) { ruleNavigation.page = page; show() }

    func showNearbyPeople() {
        ruleNavigation.page = .rules; ruleNavigation.triggerFilter = .extraFace
        show()
    }
    func showUpdates() { ruleNavigation.page = .settings; show() }

    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreen = false }
    func windowDidEnterFullScreen(_ notification: Notification) { updateContentInsets() }
    func windowDidExitFullScreen(_ notification: Notification) { positionWindowControls(); updateContentInsets() }
    func windowDidResize(_ notification: Notification) { positionWindowControls(); updateContentInsets() }
    func windowDidMove(_ notification: Notification) { updateContentInsets() }
    func windowDidChangeScreen(_ notification: Notification) { updateContentInsets() }

    private func updateContentInsets() {
        guard window.isVisible, let screen = window.screen else { return }
        if !fullScreen, window.frame.minY >= screen.visibleFrame.minY {
            if ruleNavigation.bottomInset != 0 { ruleNavigation.bottomInset = 0 }
            return
        }
        let bottom = max(0, DockGeometry.visibleTop(on: screen) - window.frame.minY)
        if abs(ruleNavigation.bottomInset - bottom) > 0.5 { ruleNavigation.bottomInset = bottom }
    }

    deinit { layoutTimer?.invalidate() }

    private func positionWindowControls() {
        guard !fullScreen else { return }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: 23 + CGFloat(index) * 23 - button.frame.width / 2,
                                          y: parent.bounds.height - 23 - button.frame.height / 2))
        }
    }

    func hideForAreaSelection() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
}
