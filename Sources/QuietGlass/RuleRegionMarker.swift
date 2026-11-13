import AppKit
import ShieldCore

private final class RuleRegionMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RuleRegionMarker {
    private var panel: NSPanel?
    private var selection: SelectedDisplayRegion?
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    static func frame(_ selection: SelectedDisplayRegion, display: ProtectionDisplay) -> CGRect? {
        guard selection.displayID == display.id else { return nil }
        let rect = selection.normalizedRect
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0, rect.maxX <= 1, rect.maxY <= 1 else { return nil }
        return ScreenRegions.fromVision(rect, in: display.frame)
    }
    func show(_ selection: SelectedDisplayRegion?) { self.selection = selection; refresh() }
    private func refresh() {
        guard let selection, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selection.displayID
        }), let frame = Self.frame(selection, display: ProtectionDisplay(id: selection.displayID, frame: screen.frame)) else {
            panel?.orderOut(nil); return
        }
        if panel == nil {
            let value = RuleRegionMarkerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            value.isReleasedWhenClosed = false; value.isOpaque = false; value.backgroundColor = .clear
            value.ignoresMouseEvents = true; value.sharingType = .none; value.hidesOnDeactivate = false
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            value.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 7)
            value.contentView = RuleRegionMarkerView(); panel = value
        }
        panel?.setFrame(frame, display: true); panel?.contentView?.needsDisplay = true; panel?.orderFrontRegardless()
    }
    func close() { selection = nil; panel?.orderOut(nil); panel?.close(); panel = nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private final class RuleRegionMarkerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(srgbRed: 0.94, green: 0.68, blue: 0.91, alpha: 1)
        guard bounds.width > 4, bounds.height > 4 else { accent.setFill(); bounds.fill(); return }
        accent.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); outline.lineWidth = 3; outline.setLineDash([7, 4], count: 2, phase: 0); outline.stroke()
        accent.setFill()
        for point in [CGPoint(x: 4, y: 4), CGPoint(x: bounds.width - 4, y: 4), CGPoint(x: 4, y: bounds.height - 4), CGPoint(x: bounds.width - 4, y: bounds.height - 4)] {
            NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
        guard bounds.width >= 160, bounds.height >= 36 else { return }
        let caption = QG("Selected area · This setup applies here") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black]
        let size = caption.size(withAttributes: attributes)
        let label = CGRect(x: 9, y: max(4, bounds.height - 28), width: min(size.width + 16, max(0, bounds.width - 18)), height: 22)
        NSBezierPath(roundedRect: label, xRadius: 6, yRadius: 6).fill()
        caption.draw(in: label.insetBy(dx: 8, dy: 3), withAttributes: attributes)
    }
}
