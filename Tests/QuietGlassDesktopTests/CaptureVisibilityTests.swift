//  Created by Clinton Imaro on 20/09/2026.

import AppKit
import XCTest
import ShieldCore
@testable import QuietGlass

final class CaptureVisibilityTests: OptInDesktopTestCase {
    @MainActor func testHeadBlurCapturePreferenceAppliesBeforeAndAfterSurfaceCreation() throws {
        _ = NSApplication.shared
        let overlay = ScreenBlurExecutor()
        var engine = try ProtectionEngine()
        overlay.includeInCaptures = true
        overlay.apply(engine.send(.tick, at: 0))
        defer {
            overlay.shutdown()
        }
        let surface = try XCTUnwrap(overlay.fullSurfaces.values.first)
        let panel = surface.panel
        XCTAssertEqual(panel.sharingType, .readOnly)
        surface.setImage(try sampleImage())
        overlay.includeInCaptures = false
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(surface.hasImage)
        overlay.includeInCaptures = true
        XCTAssertEqual(panel.sharingType, .readOnly)
        XCTAssertTrue(overlay.fullSurfaces.values.contains { $0.panel === panel })
        XCTAssertTrue(surface.hasImage)
    }

    @MainActor func testPrivacyCapturePreferencePreservesExistingBlur() throws {
        _ = NSApplication.shared
        let privacy = ScreenBlurExecutor()
        var engine = try ProtectionEngine()
        defer { privacy.shutdown() }
        privacy.includeInCaptures = true
        privacy.apply(engine.send(.tick, at: 0))
        let surface = try XCTUnwrap(privacy.regionSurfaces.values.first)
        let panel = surface.panel
        XCTAssertEqual(panel.sharingType, .readOnly)
        surface.setImage(try sampleImage())
        privacy.includeInCaptures = false
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(surface.hasImage)
        privacy.includeInCaptures = true
        XCTAssertEqual(panel.sharingType, .readOnly)
        XCTAssertTrue(privacy.regionSurfaces.values.contains { $0.panel === panel })
        XCTAssertTrue(surface.hasImage)
    }

    private func sampleImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}
