// Clinton Imaro was here 20/09/2026.

import XCTest
import AppKit
import ShieldCore
@testable import QuietGlass

final class ShieldSurfaceTests: OptInDesktopTestCase {
    @MainActor func testIndependentRegionMasksKeepTheirParametersAndPriorityOverlap() throws {
        _ = NSApplication.shared
        let surface = PrivacySurface(screen: try XCTUnwrap(NSScreen.screens.first))
        defer { surface.panel.close() }
        surface.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        surface.update(regions: [
            ProtectionRegion(rectangle: CGRect(x: 0, y: 0, width: 200, height: 200), blur: BlurParameters(radius: 10), ruleID: UUID()),
            ProtectionRegion(rectangle: CGRect(x: 100, y: 100, width: 200, height: 200), blur: BlurParameters(radius: 50), ruleID: UUID())])
        let layers = try XCTUnwrap(surface.panel.contentView?.layer?.sublayers)
        XCTAssertEqual(layers.count, 1)
        let masks = layers.compactMap { ($0.mask as? CAShapeLayer)?.path }
        XCTAssertEqual(masks.filter { $0.contains(CGPoint(x: 150, y: 150)) }.count, 1,
                       "One rule owns overlap; blur layers must not stack")
        XCTAssertEqual(masks.filter { $0.contains(CGPoint(x: 250, y: 250)) }.count, 1)
        XCTAssertEqual(masks.filter { $0.contains(CGPoint(x: 50, y: 50)) }.count, 1)
        XCTAssertFalse(masks.contains { $0.contains(CGPoint(x: 350, y: 250)) })
        surface.clear()
        XCTAssertFalse(surface.panel.isVisible)
    }
    @MainActor func testOverlappingFocusAndControlExclusionsFormOneClearUnion() throws {
        _ = NSApplication.shared
        let surface = ShieldSurface(screen: try XCTUnwrap(NSScreen.screens.first))
        defer { surface.panel.close() }
        surface.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        surface.update(coverage: 1, direction: .left, excludedRegions: [CGRect(x: 50, y: 50, width: 100, height: 100), CGRect(x: 100, y: 100, width: 100, height: 100)])
        let mask = try XCTUnwrap(surface.panel.contentView?.layer?.mask as? CAShapeLayer)
        XCTAssertFalse(mask.path!.contains(CGPoint(x: 120, y: 120), using: .evenOdd), "Overlap must stay clear rather than re-fill by parity")
        XCTAssertFalse(mask.path!.contains(CGPoint(x: 60, y: 60), using: .evenOdd))
        XCTAssertTrue(mask.path!.contains(CGPoint(x: 20, y: 20), using: .evenOdd))
    }
    @MainActor func testFocusHoleRemainsClearInFullAndDirectionalMasks() throws {
        _ = NSApplication.shared
        let surface = ShieldSurface(screen: try XCTUnwrap(NSScreen.screens.first))
        defer { surface.panel.close() }
        surface.resize(to: CGRect(x: 100, y: 200, width: 400, height: 300))
        let hole = CGRect(x: 150, y: 250, width: 100, height: 100)
        surface.update(coverage: 1, direction: .left, excludedRegions: [hole])
        let image = try XCTUnwrap(surface.panel.contentView?.layer)
        let mask = try XCTUnwrap(image.mask as? CAShapeLayer)
        XCTAssertEqual(mask.fillRule, .evenOdd)
        let path = try XCTUnwrap(mask.path)
        XCTAssertFalse(path.contains(CGPoint(x: 60, y: 60), using: .evenOdd))
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 10), using: .evenOdd))
        surface.update(coverage: 0.5, direction: .right, excludedRegions: [hole])
        let gradient = try XCTUnwrap(image.mask as? CAGradientLayer)
        let clip = try XCTUnwrap(gradient.mask as? CAShapeLayer)
        XCTAssertFalse(clip.path!.contains(CGPoint(x: 60, y: 60), using: .evenOdd))
        surface.update(coverage: 1, direction: .left)
        XCTAssertNil(image.mask)
        surface.clear()
    }
    @MainActor func testFirstFrameRevealKeepsBlurredPixelsOpaqueAndDoesNotRestartForEveryFrame() throws {
        _ = NSApplication.shared
        let surface = ShieldSurface(screen: try XCTUnwrap(NSScreen.screens.first))
        defer { surface.panel.close() }
        surface.resize(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        surface.update(coverage: 1, direction: .left)
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        surface.setImage(image)
        let pixels = try XCTUnwrap(surface.panel.contentView?.layer)
        let cover = try XCTUnwrap(pixels.sublayers?.first)
        let reveal = try XCTUnwrap(cover.animation(forKey: "firstFrame") as? CABasicAnimation)
        XCTAssertEqual(reveal.fromValue as? Int, 1)
        XCTAssertEqual(reveal.toValue as? Int, 0)
        XCTAssertGreaterThan(reveal.duration, 0)
        XCTAssertEqual(pixels.opacity, 1, "Reveal must fade the cover, never the captured protection")
        XCTAssertEqual(surface.panel.alphaValue, 1)
        XCTAssertNotNil(pixels.contents)
        XCTAssertNil(pixels.mask, "Full coverage must remain opaque during the reveal")

        cover.removeAllAnimations() // The first-frame reveal has finished.
        surface.setImage(image)
        XCTAssertNil(cover.animation(forKey: "firstFrame"), "Live capture frames must not restart the dark cover")
        surface.clear()
        XCTAssertNil(cover.animationKeys())
        surface.update(coverage: 1, direction: .right)
        surface.setImage(image)
        XCTAssertNotNil(cover.animation(forKey: "firstFrame"), "A new capture starts with its own safe reveal")
        surface.clear()
        XCTAssertFalse(surface.hasImage)
        XCTAssertFalse(surface.panel.isVisible)
        XCTAssertNil(cover.animationKeys(), "Escape must remove an in-flight reveal immediately")
    }

    @MainActor func testNewDisplayHasTemporaryCoverageBeforeFirstCapture() throws {
        _ = NSApplication.shared
        let surface = ShieldSurface(screen: try XCTUnwrap(NSScreen.screens.first))
        defer { surface.panel.close() }
        surface.resize(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        surface.update(coverage: 1, direction: .left)
        XCTAssertTrue(surface.panel.isVisible)
        XCTAssertNotNil(surface.panel.contentView?.layer?.backgroundColor)
        XCTAssertFalse(surface.hasImage)
        surface.update(coverage: 0, direction: .left)
        surface.keepVisible()
        XCTAssertFalse(surface.panel.isVisible, "A display with zero coverage must stay clear during refresh")
        surface.clear(); XCTAssertFalse(surface.panel.isVisible)
    }
    @MainActor func testGeometryChangesRetainWindowAndPixels() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let surface = ShieldSurface(screen: screen)
        defer { surface.panel.close() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        surface.setImage(try XCTUnwrap(context.makeImage()))
        let panel = surface.panel
        surface.resize(to: screen.frame)
        surface.resize(to: CGRect(x: -1600, y: 100, width: 1600, height: 900))
        XCTAssertTrue(surface.panel === panel)
        XCTAssertTrue(surface.hasImage, "Changing display geometry must not expose a clear frame")
        XCTAssertEqual(surface.panel.frame.width, 1600)
        XCTAssertEqual(surface.panel.frame.height, 900)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        surface.clear()
        XCTAssertFalse(surface.hasImage)
    }
}
