//  Created by Clinton Imaro on 20/09/2026.

import AppKit
import ShieldCore

struct SelectedDisplayRegion: Equatable {
    let displayID: UInt32
    let normalizedRect: CGRect
}

final class AreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AreaSelectionController {
    private var panels: [AreaSelectionPanel] = []
    private var observer: NSObjectProtocol?
    private weak var returnWindow: NSWindow?

    func show(frame: CGRect, selected: @escaping (CGRect) -> Void) {
        close()
        addPanel(frame: frame) { area in if let area { selected(area) } }
        observeSpaces()
    }

    func show(displays: [ProtectionDisplay], selected: @escaping (SelectedDisplayRegion) -> Void) {
        close()
        returnWindow = NSApp.keyWindow
        for display in displays {
            addPanel(frame: display.frame) { area in
                if let area { selected(SelectedDisplayRegion(displayID: display.id, normalizedRect: area)) }
            }
        }
        observeSpaces()
    }

    private func addPanel(frame: CGRect, complete: @escaping (CGRect?) -> Void) {
        let panel = AreaSelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = QG("Choose a protected area")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 6)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = AreaSelectionView(frame: CGRect(origin: .zero, size: frame.size))
        view.complete = { [weak self] area in
            self?.close()
            complete(area)
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panels.append(panel)
    }

    private func observeSpaces() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels = []
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        if let returnWindow, returnWindow.isVisible { returnWindow.makeKeyAndOrderFront(nil) }
        returnWindow = nil
    }
}

private final class AreaSelectionView: NSView {
    var complete: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        let caption = QG("Drag over the area to blur · Escape to close")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (caption as NSString).size(withAttributes: attributes)
        let label = CGRect(x: max(12, bounds.midX - size.width / 2), y: bounds.maxY - 52, width: min(bounds.width - 24, size.width), height: 24)
        NSColor(white: 0.1, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: label.insetBy(dx: -10, dy: -8), xRadius: 18, yRadius: 18).fill()
        (caption as NSString).draw(in: label, withAttributes: attributes)
        if !selection.isEmpty {
            NSColor(srgbRed: 0.94, green: 0.68, blue: 0.91, alpha: 0.15).setFill()
            selection.fill()
            NSColor(srgbRed: 0.94, green: 0.68, blue: 0.91, alpha: 1).setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 16, selection.height >= 16 else { return }
        complete?(CGRect(x: selection.minX / bounds.width, y: selection.minY / bounds.height,
                         width: selection.width / bounds.width, height: selection.height / bounds.height))
    }
    override func cancelOperation(_ sender: Any?) { complete?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { complete?(nil) } else { super.keyDown(with: event) }
    }
}
