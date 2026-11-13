// Clinton Imaro was here 20/09/2026.

import AppKit
import Combine
import SwiftUI
import ShieldCore

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var edge: NotchEdge = .bottom
}

enum NotchAction: CaseIterable { case automaticDetection, settings, area }

@MainActor
final class NotchBarController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    private let model: AppModel
    private let state = NotchState()
    private let panel: NotchPanel
    private let hintPanel: HintPanel
    private let nearbyPanel: HintPanel
    private var nearbyObservation: AnyCancellable?
    private let contextPanel: NotchPanel
    private let menuState = NotchMenuState()
    private let canvas = NSView()
    private var hostedBar: NSView!
    private let popover = NSPopover()
    private var screenObserver: NSObjectProtocol?
    private var controlsResizeObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dockPositionTimer: Timer?
    private var contextMonitor: Any?
    private var outsideClickMonitor: Any?
    private var collapseTask: Task<Void, Never>?
    private var snoozeTimer: Timer?
    private var anchor = NSPoint.zero
    private var dragOrigin: (mouse: NSPoint, anchor: NSPoint, edge: NotchEdge)?
    private var lastDragEnded = -Double.infinity
    private var contextMenuOpen = false
    private var usesExpandedBounds = false
    private var expansionGeneration = 0
    private var hintGeneration = 0
    private var hintedAction: NotchAction?
    private var followsDock = true
    private var orientationTransition = false
    private var orientationGeneration = 0
    var isVisible: Bool { panel.isVisible }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 44, height: 12),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hintPanel = HintPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        nearbyPanel = HintPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contextPanel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configure(panel, title: "QuietGlass")
        configure(hintPanel, title: "QuietGlass hint")
        configure(nearbyPanel, title: "Nearby people alert")
        nearbyPanel.contentView = NSHostingView(rootView: NearbyNoticeView(model: model))
        panel.addChildWindow(nearbyPanel, ordered: .above)
        configure(contextPanel, title: "QuietGlass menu")
        contextPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        contextPanel.hasShadow = true
        contextPanel.becomesKeyOnlyIfNeeded = false
        contextPanel.appearance = NSAppearance(named: .aqua)
        contextPanel.delegate = self
        contextPanel.contentView = NSHostingView(rootView: NotchContextMenuView(
            model: model, state: menuState, action: { [weak self] in self?.performMenuAction($0) }))
        hintPanel.ignoresMouseEvents = true
        hintPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        panel.appearance = NSAppearance(named: .aqua)
        panel.delegate = self
        hostedBar = NSHostingView(rootView: NotchBarView(
            model: model, state: state,
            hover: { [weak self] in self?.hover($0) },
            hint: { [weak self] in self?.showHint($0) },
            action: { [weak self] in self?.perform($0) },
            drag: { [weak self] translation, ended in self?.drag(translation: translation, ended: ended) }))
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        canvas.addSubview(hostedBar)
        panel.contentView = canvas

        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: NotchControlsView(
            model: model, close: { [weak self] in self?.closeControls() }))
        controlsResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, window === self.popover.contentViewController?.view.window else { return }
                self.positionControls()
            }
        }

        if model.presentationPreference("notchUsesCustomPosition") as? Bool == true, model.presentationPreference("notchAnchorX") != nil {
            followsDock = false
            state.edge = NotchEdge(rawValue: model.presentationPreference("notchDockEdge") as? String ?? "floating") ?? .floating
            anchor = NSPoint(x: model.presentationPreference("notchAnchorX") as? Double ?? 0, y: model.presentationPreference("notchAnchorY") as? Double ?? 0)
            constrainToScreen()
        } else { resetPosition() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.followsDock { self.refreshDockPosition(animated: true) } else { self.constrainToScreen() }
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDockPosition(animated: true) }
            })
        }
        dockPositionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.refreshDockPosition(animated: true)
            }
        }
        dockPositionTimer?.tolerance = 0.1
        nearbyObservation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateNearbyNotice()
        }
        contextMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown, self.popover.isShown,
               event.window !== self.popover.contentViewController?.view.window {
                self.popover.close()
            }
            if self.contextMenuOpen {
                if event.type == .keyDown, self.handleMenuKey(event.keyCode) { return nil }
                if event.type != .keyDown, event.window !== self.contextPanel { self.closeContextMenu() }
            }
            if event.type == .rightMouseDown, event.window === self.panel {
                self.showContextMenu()
                return nil
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeControls() }
        }
    }

    private func configure(_ window: NSPanel, title: String) {
        window.title = title
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show() {
        snoozeTimer?.invalidate(); snoozeTimer = nil
        refreshDockPosition(animated: panel.isVisible)
        panel.orderFrontRegardless()
        updateNearbyNotice()
    }

    func toggleVisibility() {
        if panel.isVisible { hide() } else { show() }
    }

    private func hide() {
        closeControls()
        collapseTask?.cancel()
        showHint(nil)
        setExpanded(false)
        panel.orderOut(nil)
        nearbyPanel.orderOut(nil)
        model.protectionCoordinator?.warnings.visible = false
    }

    private func hover(_ entered: Bool) {
        collapseTask?.cancel()
        if entered {
            setExpanded(true)
            let position = state.edge.isVertical ? anchor.y + 24 - NSEvent.mouseLocation.y : NSEvent.mouseLocation.x - anchor.x + 24
            showHint(position < 50 ? .automaticDetection : position < 84 ? .settings : .area)
        }
        else { scheduleCollapse() }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, !self.popover.isShown,
                  !self.contextMenuOpen, self.dragOrigin == nil,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.showHint(nil)
            self.setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        expansionGeneration += 1
        let generation = expansionGeneration
        if expanded {
            usesExpandedBounds = true
            layoutPanel()
        }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.3)
        withAnimation(animation, completionCriteria: .removed) {
            state.expanded = expanded
        } completion: { [weak self] in
            guard let self, !expanded, !self.state.expanded, self.expansionGeneration == generation else { return }
            self.usesExpandedBounds = false
            self.layoutPanel()
        }
        updateNearbyNotice()
    }

    private func layoutPanel(animated: Bool = false) {
        let frame: NSRect
        if orientationTransition {
            frame = NotchDocking.frame(anchor: anchor, vertical: false, expanded: true, controlCount: 3)
                .union(NotchDocking.frame(anchor: anchor, vertical: true, expanded: true, controlCount: 3))
        } else {
            frame = NotchDocking.frame(anchor: anchor, vertical: state.edge.isVertical, expanded: usesExpandedBounds, controlCount: 3)
        }
        if animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        hostedBar.frame = NSRect(x: anchor.x - frame.minX - 24, y: anchor.y - frame.minY - 126, width: 150, height: 150)
        updateNearbyNotice()
    }

    private func updateNearbyNotice() {
        defer {
            model.protectionCoordinator?.warnings.visible = nearbyPanel.isVisible
        }
        guard model.nearbyNeedsAttention, panel.isVisible, !state.expanded,
              !popover.isShown, !contextMenuOpen else {
            nearbyPanel.orderOut(nil)
            return
        }
        let size = NearbyNoticeView.size
        let frame = NotchDocking.noticeFrame(size: size, anchor: anchor, edge: state.edge, in: popupBounds())
        nearbyPanel.setFrame(frame, display: true)
        nearbyPanel.orderFrontRegardless()
    }

    private func setDockEdge(_ edge: NotchEdge) {
        guard edge != state.edge else { return }
        let rotates = edge.isVertical != state.edge.isVertical
        orientationGeneration += 1
        let generation = orientationGeneration
        if rotates { orientationTransition = true; layoutPanel() }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.3)
        withAnimation(animation, completionCriteria: .removed) { state.edge = edge } completion: { [weak self] in
            guard let self, self.orientationGeneration == generation else { return }
            self.orientationTransition = false
            self.layoutPanel()
        }
    }

    private func perform(_ action: NotchAction) {
        guard ProcessInfo.processInfo.systemUptime - lastDragEnded > 0.2 else { return }
        guard state.expanded else { hover(true); return }
        switch action {
        case .automaticDetection: model.setAutomaticDetection(!model.automaticDetectionEnabled)
        case .settings:
            closeControls()
            showHint(nil)
            model.onOpenPrivacySettings?()
            return
        case .area:
            showControls(areaOptions: true)
            return
        }
        showHint(action)
    }

    private func drag(translation: CGSize, ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragOrigin == nil {
            guard !ended else { return }
            let start = NSPoint(x: mouse.x - translation.width, y: mouse.y + translation.height)
            dragOrigin = (start, anchor, state.edge)
            closeControls()
            collapseTask?.cancel()
            setExpanded(true)
            showHint(nil)
        }
        guard let origin = dragOrigin else { return }
        let proposed = NSPoint(x: origin.anchor.x + mouse.x - origin.mouse.x, y: origin.anchor.y + mouse.y - origin.mouse.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(proposed) })
        let allowed = screen.map { NotchDocking.allowsPlacement(at: proposed, in: $0.visibleFrame) } ?? false
        if allowed, let screen {
            anchor = proposed
            let edge = NotchDocking.edge(near: anchor, in: screen.frame, bottom: visibleDockTop(on: screen), retaining: state.edge)
            setDockEdge(edge)
            layoutPanel()
        }
        if ended {
            dragOrigin = nil
            lastDragEnded = ProcessInfo.processInfo.systemUptime
            if !allowed {
                anchor = origin.anchor
                setDockEdge(origin.edge)
                layoutPanel(animated: true)
            }
            followsDock = state.edge == .bottom
            if followsDock { refreshDockPosition(animated: true) }
            else { constrainToScreen(animated: true) }
            savePosition()
            scheduleCollapse()
        }
    }

    private func showHint(_ action: NotchAction?) {
        hintGeneration += 1
        let generation = hintGeneration
        guard let action, state.expanded, !popover.isShown,
              !contextMenuOpen, dragOrigin == nil else {
            hintedAction = nil
            guard hintPanel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                hintPanel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.hintGeneration == generation else { return }
                    self.hintPanel.orderOut(nil)
                }
            }
            return
        }
        if hintedAction == action, hintPanel.isVisible {
            hintPanel.animator().alphaValue = 1
            return
        }
        hintedAction = action
        let view = NSHostingView(rootView: NotchHintView(model: model, action: action))
        let size = view.fittingSize
        hintPanel.contentView = view
        let offset: CGFloat = action == .automaticDetection ? 0 : action == .settings ? 43 : 77
        var x = anchor.x + offset - size.width / 2
        let visible = popupBounds()
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = panel.frame.maxY + 5 + size.height <= visible.maxY
            ? panel.frame.maxY + 5 : panel.frame.minY - size.height - 5
        if state.edge.isVertical {
            x = state.edge == .left ? panel.frame.maxX + 7 : panel.frame.minX - size.width - 7
            y = min(max(anchor.y - offset - size.height / 2, visible.minY + 8), visible.maxY - size.height - 8)
        }
        hintPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if !hintPanel.isVisible { hintPanel.alphaValue = 0; hintPanel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            hintPanel.animator().alphaValue = 1
        }
    }

    func showControls(areaOptions: Bool = false) {
        closeContextMenu()
        show()
        setExpanded(true)
        showHint(nil)
        guard !popover.isShown, let content = panel.contentView else { return }
        popover.contentViewController = NSHostingController(rootView: NotchControlsView(
            model: model, areaOptions: areaOptions, close: { [weak self] in self?.closeControls() }))
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let edge: NSRectEdge = state.edge == .left ? .maxX : state.edge == .right ? .minX : .maxY
        let controls = NotchDocking.frame(anchor: anchor, vertical: state.edge.isVertical, expanded: true, controlCount: 3)
        let attachment: NSPoint
        switch state.edge {
        case .left: attachment = NSPoint(x: controls.maxX, y: controls.midY)
        case .right: attachment = NSPoint(x: controls.minX, y: controls.midY)
        case .bottom, .floating: attachment = NSPoint(x: controls.midX, y: controls.maxY)
        }
        let windowPoint = panel.convertPoint(fromScreen: attachment)
        let point = content.convert(windowPoint, from: nil)
        popover.show(relativeTo: NSRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1),
                     of: content, preferredEdge: edge)
        popover.contentViewController?.view.window?.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        positionControls()
    }

    private func positionControls() {
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return }
        let controls = NotchDocking.frame(anchor: anchor, vertical: state.edge.isVertical, expanded: true, controlCount: 3)
        let visible = popupBounds()
        var origin = window.frame.origin
        switch state.edge {
        case .left: origin.x = controls.maxX + 8
        case .right: origin.x = controls.minX - 8 - window.frame.width
        case .bottom, .floating:
            origin.y = window.frame.midY < controls.midY
                ? controls.minY - 8 - window.frame.height : controls.maxY + 8
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - window.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - window.frame.height - 8)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    func closeControls() { popover.close(); closeContextMenu() }

    func resetPosition() {
        closeControls(); followsDock = true; setDockEdge(.bottom)
        refreshDockPosition(animated: panel.isVisible); savePosition()
    }

    private func refreshDockPosition(animated: Bool) {
        guard followsDock, dragOrigin == nil, !popover.isShown, !contextMenuOpen,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let bottom = visibleDockTop(on: screen)
        let target = NSPoint(x: screen.frame.midX, y: bottom + 20)
        guard target != anchor else { return }
        showHint(nil)
        anchor = target
        layoutPanel(animated: animated)
        savePosition()
    }

    private func visibleDockTop(on screen: NSScreen) -> CGFloat {
        DockGeometry.visibleTop(on: screen)
    }

    private func popupBounds() -> NSRect {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return NotchDocking.popupBounds(in: screen.visibleFrame, bottom: visibleDockTop(on: screen))
    }

    private func constrainToScreen(animated: Bool = false) {
        closeControls()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) else {
            resetPosition(); return
        }
        if state.edge.isVertical {
            anchor = NotchDocking.anchor(for: state.edge, in: screen.frame, bottom: visibleDockTop(on: screen))
        } else {
            guard NotchDocking.allowsPlacement(at: anchor, in: screen.visibleFrame) else {
                resetPosition(); return
            }
            anchor = NotchDocking.constrain(anchor, in: screen.visibleFrame, vertical: false)
        }
        layoutPanel(animated: animated)
    }

    private func savePosition() {
        model.setPresentationPreference("notchUsesCustomPosition", !followsDock)
        model.setPresentationPreference("notchAnchorX", anchor.x)
        model.setPresentationPreference("notchAnchorY", anchor.y)
        model.setPresentationPreference("notchDockEdge", state.edge.rawValue)
    }

    private func showContextMenu() {
        guard let content = contextPanel.contentView else { return }
        closeControls()
        showHint(nil)
        setExpanded(true)
        contextMenuOpen = true
        collapseTask?.cancel()
        menuState.highlighted = nil
        let size = content.fittingSize
        let visible = popupBounds()
        var x = min(max(anchor.x - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let above = panel.frame.maxY + 8
        var y = above + size.height <= visible.maxY - 8 ? above : panel.frame.minY - size.height - 8
        if state.edge.isVertical {
            x = state.edge == .left ? panel.frame.maxX + 8 : panel.frame.minX - size.width - 8
            y = min(anchor.y + 24 - size.height, visible.maxY - size.height - 8)
        }
        contextPanel.setFrame(NSRect(x: x, y: max(visible.minY + 8, y), width: size.width, height: size.height), display: true)
        contextPanel.makeKeyAndOrderFront(nil)
    }

    private func closeContextMenu() {
        guard contextMenuOpen else { return }
        contextMenuOpen = false
        contextPanel.orderOut(nil)
        menuState.highlighted = nil
        scheduleCollapse()
    }

    private func handleMenuKey(_ code: UInt16) -> Bool {
        if code == 53 { closeContextMenu(); return true }
        let items = NotchMenuAction.allCases
        if code == 125 || code == 126 {
            let step = code == 125 ? 1 : -1
            let index = menuState.highlighted.flatMap { items.firstIndex(of: $0) } ?? (step == 1 ? -1 : 0)
            menuState.highlighted = items[(index + step + items.count) % items.count]
            return true
        }
        if code == 36 || code == 49, let selected = menuState.highlighted {
            performMenuAction(selected)
            return true
        }
        return false
    }

    private func performMenuAction(_ action: NotchMenuAction) {
        closeContextMenu()
        switch action {
        case .snooze: snooze()
        case .controls: showControls()
        case .protection: model.onOpenProtection?()
        case .rules: model.onOpenRules?()
        case .settings: model.onOpenPrivacySettings?()
        case .resetPosition: resetPosition()
        case .screen: model.toggleInstantShield()
        case .area: model.privacy.chooseArea()
        case .window: model.privacy.chooseWindow()
        case .focus: model.setFocus(!model.privacy.focusEnabled)
        case .pause: model.protectionCoordinator?.pause()
        case .resume: model.protectionCoordinator?.resume()
        case .clear: model.dismissShield()
        }

    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === contextPanel { closeContextMenu() }
    }

    func popoverDidShow(_ notification: Notification) { positionControls() }

    func popoverDidClose(_ notification: Notification) { scheduleCollapse() }

    private func snooze() {
        hide()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
    }

    func shutdown() {
        hide()
        snoozeTimer?.invalidate()
        dockPositionTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let controlsResizeObserver { NotificationCenter.default.removeObserver(controlsResizeObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let contextMonitor { NSEvent.removeMonitor(contextMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        contextPanel.close()
        hintPanel.close()
        nearbyObservation?.cancel()
        nearbyPanel.close()
        panel.close()
    }
}

struct NearbyNoticeView: View {
    static let size = CGSize(width: 312, height: 56)
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.onOpenNearbySettings?() } label: {
            HStack(spacing: 9) {
                Image(systemName: model.nearby.canRetry || model.nearbyBlurUnavailable ? "exclamationmark.triangle" : "person.2.fill")
                    .font(.system(size: 17)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(QG(model.nearbyNoticeTitle)).font(.system(size: 12, weight: .medium))
                    Text(QG(model.nearbyNoticeDetail)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(.orange.opacity(0.45), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(QG("%@. %@", QG(model.nearbyNoticeTitle), QG(model.nearbyNoticeDetail)))
        .accessibilityHint(QG("Open rules"))
    }
}

struct NotchBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    let hover: (Bool) -> Void
    let hint: (NotchAction?) -> Void
    let action: (NotchAction) -> Void
    let drag: (CGSize, Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            control(.area, icon: .area)
                .scaleEffect(state.expanded ? 1 : 0.45)
                .opacity(state.expanded ? 1 : 0)
                .position(controlCenter(77, resting: 20))
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)
            control(.settings, icon: .settings)
                .scaleEffect(state.expanded ? 1 : 0.45)
                .opacity(state.expanded ? 1 : 0)
                .position(controlCenter(43, resting: 10))
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)
            control(.automaticDetection, icon: .view)
                .position(x: 24, y: 24)
        }
        .frame(width: 150, height: 150, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .simultaneousGesture(DragGesture(minimumDistance: 4)
            .onChanged { drag($0.translation, false) }
            .onEnded { drag($0.translation, true) })
    }

    private func controlCenter(_ distance: CGFloat, resting: CGFloat) -> CGPoint {
        let offset = state.expanded ? distance : resting
        return CGPoint(x: 24 + (state.edge.isVertical ? 0 : offset),
                       y: 24 + (state.edge.isVertical ? offset : 0))
    }

    private func control(_ item: NotchAction, icon: AppIcon) -> some View {
        let primary = item == .automaticDetection
        let vertical = state.edge.isVertical
        let width: CGFloat = primary && !vertical ? 48 : 30
        let height: CGFloat = primary && vertical ? 48 : 30
        let content = ZStack {
            Capsule()
                .fill(primary && !state.expanded && model.nearbyNeedsAttention ? Color.orange : Color.black)
                .frame(width: primary && !state.expanded ? (vertical ? 8 : 40) : width,
                       height: primary && !state.expanded ? (vertical ? 40 : 8) : height)
            AppIconView(icon: icon, size: 18)
                .foregroundStyle(primary && model.automaticDetectionEnabled ? Color.green : primary && model.nearbyNeedsAttention ? Color.orange : .white)
                .opacity(state.expanded ? 1 : 0)
                .scaleEffect(state.expanded ? 1 : 0.7)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        return Group {
            if primary {
                Toggle(isOn: Binding(get: { model.automaticDetectionEnabled }, set: { _ in action(item) })) {
                    content
                }.toggleStyle(.button)
            } else {
                Button { action(item) } label: { content }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(primary ? QG(model.automaticDetectionEnabled ? "On" : "Off") : "")
        .accessibilityLabel(QG(primary && !state.expanded ? (model.nearbyNeedsAttention ? QG(model.nearbyNoticeTitle) : "QuietGlass notch") : label(item)))
        .accessibilityHint(QG(primary && !state.expanded ? "Hover to reveal controls, or right-click for settings" : ""))
        .onHover { hint($0 && state.expanded ? item : nil) }
    }

    private func label(_ item: NotchAction) -> String {
        switch item {
        case .automaticDetection: return "Automatic detection"
        case .settings: return "Settings"
        case .area: return "Choose content…"
        }
    }
}

private struct NotchHintView: View {
    @ObservedObject var model: AppModel
    let action: NotchAction

    var body: some View {
        HStack(spacing: 5) {
            Text(QG(label))
            if action == .automaticDetection {
                Text(QG(model.automaticDetectionEnabled ? "On" : "Off")).foregroundStyle(model.automaticDetectionEnabled ? .green : .secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(white: 0.25), lineWidth: 0.7))
        .fixedSize()
    }

    private var label: String {
        switch action {
        case .automaticDetection: return "Automatic detection"
        case .settings: return "Settings"
        case .area: return "Choose content…"
        }
    }
}

struct NotchControlsView: View {
    @ObservedObject var model: AppModel
    @State private var areaOptions: Bool
    let close: () -> Void

    init(model: AppModel, areaOptions: Bool = false, close: @escaping () -> Void) {
        self.model = model
        _areaOptions = State(initialValue: areaOptions)
        self.close = close
    }

    var body: some View {
        Group {
            if areaOptions {
                NotchAreaOptionsView(model: model, close: close)
            } else { statusControls }
        }
        .padding(16).frame(width: 340).fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13)).foregroundStyle(RulePalette.text).tint(RulePalette.accent)
        .background(RulePalette.background).preferredColorScheme(.dark).buttonStyle(RuleButtonStyle())
        .disclosureGroupStyle(RuleDisclosureStyle())
        .toggleStyle(RuleToggleStyle())
    }

    private var statusControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(QG("Current protection")).font(.headline)
                Spacer()
                Button(QG("Close"), action: close).buttonStyle(RuleButtonStyle(tone: .quiet))
            }
            RuleSettingRow(title: "Automatic detection", detail: "Changes only the currently active automatic setups.") {
                Toggle(QG("Automatic detection"), isOn: Binding(get: { model.automaticDetectionEnabled }, set: model.setAutomaticDetection))
                    .labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false))
            }
            Text(QG(model.status)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary).lineLimit(3)
            if let coordinator = model.protectionCoordinator {
                if !coordinator.plan.activeRules.isEmpty || !coordinator.plan.warnings.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(coordinator.plan.activeRules) { active in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(QG(active.name)).font(.headline)
                                    Text(QG(active.reason.title)).font(.caption)
                                    DisclosureGroup(QG("Rule details")) {
                                        Text(QG("Rule ID: %@", active.id.uuidString)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    }.font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                                }
                            }
                            ForEach(coordinator.plan.warnings) { warning in
                                HStack {
                                    Text(QG(warning.rule.name)).font(.caption)
                                    Spacer()
                                    Button(QG("Blur now")) { coordinator.blurNow(warning.id) }
                                }
                            }
                        }
                    }.frame(maxHeight: 220)
                }
                HStack {
                    Button(QG("Blur all displays")) { model.toggleInstantShield() }
                    Button(QG("Choose content…")) { areaOptions = true }
                }
                HStack {
                    Button(QG("Blur one window")) { close(); model.privacy.chooseWindow() }
                    Button(QG("Focus on this window")) { model.setFocus(!model.privacy.focusEnabled) }
                }
                HStack {
                    Button(QG("Clear")) { model.dismissShield() }
                    Button(QG("Pause")) { coordinator.pause() }
                    Button(QG("Resume")) { coordinator.resume() }
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                Button(QG("Screen controls")) { close(); model.onOpenProtection?() }
                Button(QG("Auto & shortcuts")) { close(); model.onOpenRules?() }
                Button(QG("Settings")) { close(); model.onOpenPrivacySettings?() }
            }
        }
    }
}

struct NotchAreaOptionsView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(QG("Choose what to protect")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(QG("Close"), action: close).buttonStyle(RuleButtonStyle(tone: .quiet))
            }.padding(.bottom, 6)
            RuleActionTile(title: "Blur part of a window", detail: "Drag over an area inside your current window.", icon: "crop") { close(); model.privacy.chooseArea() }
            RuleActionTile(title: "Blur one window", detail: "Choose a window and hide its contents.", icon: "macwindow") { close(); model.privacy.chooseWindow() }
            RuleActionTile(title: "Blur all displays", detail: "Hide content on every display; click again to remove this blur.", icon: "eye.slash") { close(); model.toggleInstantShield() }
            RuleActionTile(title: "Focus on this window", detail: "Keep the current window clear and blur everything around it.", icon: "viewfinder") { close(); model.setFocus(!model.privacy.focusEnabled) }
        }
    }
}
