// Clinton Imaro was here 20/09/2026.

import AppKit
import QuartzCore
import ScreenCaptureKit
import ShieldCore
import OSLog

final class ShieldPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ShieldSurface {
    let panel: ShieldPanel
    private let imageLayer = CALayer()
    private let gradient = CAGradientLayer()
    private let startupCover = CALayer()
    private let exclusionMask = CAShapeLayer()
    private static let maskPositions = stride(from: 0.0, through: 1.0, by: 1.0 / 64).map { $0 }
    private static let maskLocations = maskPositions.map(NSNumber.init(value:))
    private var requestedCoverage = 0.0
    var hasImage: Bool { imageLayer.contents != nil }

    init(screen: NSScreen, includeInCaptures: Bool = false) {
        panel = ShieldPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "QuietGlass Blur"
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = includeInCaptures ? .readOnly : .none
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = imageLayer
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resize
        startupCover.backgroundColor = DisplayCapture.background
        startupCover.opacity = 0
        imageLayer.addSublayer(startupCover)
        gradient.locations = Self.maskLocations
        panel.contentView = view
    }

    func resize(to frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        imageLayer.frame = NSRect(origin: .zero, size: frame.size)
        gradient.frame = imageLayer.bounds
        startupCover.frame = imageLayer.bounds
        CATransaction.commit()
    }

    func keepVisible() {
        guard requestedCoverage > 0, hasImage || imageLayer.backgroundColor != nil else { return }
        panel.orderFrontRegardless()
    }

    func update(coverage: Double, direction: ShieldDirection, excludedRegions: [CGRect] = []) {
        requestedCoverage = coverage
        guard coverage > 0 else { panel.orderOut(nil); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.backgroundColor = hasImage ? nil : DisplayCapture.background
        gradient.frame = imageLayer.bounds
        switch direction {
        case .left: gradient.startPoint = CGPoint(x: 0, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
        case .right: gradient.startPoint = CGPoint(x: 1, y: 0.5); gradient.endPoint = CGPoint(x: 0, y: 0.5)
        case .up: gradient.startPoint = CGPoint(x: 0.5, y: 1); gradient.endPoint = CGPoint(x: 0.5, y: 0)
        case .down: gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
        gradient.colors = Self.maskPositions.map { NSColor.black.withAlphaComponent(GlassMask.opacity(position: $0, coverage: coverage)).cgColor }
        if !excludedRegions.isEmpty {
            exclusionMask.frame = imageLayer.bounds
            exclusionMask.fillRule = .evenOdd
            let path = CGMutablePath(); path.addRect(imageLayer.bounds)
            var exclusions: [CGRect] = []
            for rectangle in excludedRegions {
                let clipped = rectangle.intersection(panel.frame)
                if !clipped.isNull, !clipped.isEmpty {
                    let pieces = ScreenRegions.visible(clipped, behind: exclusions)
                    for piece in pieces { path.addRect(piece.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)) }
                    exclusions += pieces
                }
            }
            exclusionMask.path = path
            if coverage >= 0.999 { imageLayer.mask = exclusionMask; gradient.mask = nil }
            else { gradient.mask = exclusionMask; imageLayer.mask = gradient }
        } else {
            gradient.mask = nil
            imageLayer.mask = coverage >= 0.999 ? nil : gradient
        }
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func setImage(_ image: CGImage) {
        let revealFirstFrame = !hasImage && requestedCoverage > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.backgroundColor = nil
        if revealFirstFrame {
            // Fade the temporary cover onto already-blurred pixels. Never fade
            // the panel itself, which would expose the clear desktop beneath it.
            startupCover.frame = imageLayer.bounds
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = 1
            reveal.toValue = 0
            reveal.duration = 0.22
            reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            startupCover.add(reveal, forKey: "firstFrame")
        }
        CATransaction.commit()
    }

    func clear() {
        requestedCoverage = 0
        panel.orderOut(nil)
        startupCover.removeAllAnimations()
        imageLayer.contents = nil
        imageLayer.backgroundColor = nil
    }
}
