import AppKit
import SwiftUI
import XCTest
import ShieldCore
@testable import QuietGlass

/// Render views without creating or presenting an NSWindow. Real input and
/// focus changes belong to Tests/QuietGlassUITests on an isolated desktop.
final class RuleInterfaceTests: XCTestCase {
    @MainActor private func render(_ view: some View, size: CGSize, name: String) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        var activated = false
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { _ in activated = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        let visible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        XCTAssertNil(host.window, "Rendering must never attach the view to a desktop window")
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), visible)
        XCTAssertFalse(activated, "Rendering must not activate the test process")
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        if let destination = ProcessInfo.processInfo.environment["QUIETGLASS_RENDER_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        return image
    }

    @MainActor func testEnabledToggleRetainsAccentWithoutAnActiveWindow() throws {
        let enabled = try render(Toggle("Example", isOn: .constant(true))
            .toggleStyle(RuleToggleStyle(showsLabel: false)), size: CGSize(width: 120, height: 60), name: "toggle-enabled")
        let disabled = try render(Toggle("Example", isOn: .constant(false))
            .toggleStyle(RuleToggleStyle(showsLabel: false)), size: CGSize(width: 120, height: 60), name: "toggle-off")
        func accentPixels(_ image: NSBitmapImageRep) -> Int {
            var count = 0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5,
                       c.redComponent > 0.8, c.blueComponent > 0.8, c.greenComponent < 0.9 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(accentPixels(enabled), 50)
        XCTAssertLessThan(accentPixels(disabled), accentPixels(enabled))
    }

    @MainActor func testActionTilesRenderEnglishAndChineseAtNarrowAndWideSizes() throws {
        for (language, title, detail) in [("en", "Select region", "Choose an area on any display."),
                                           ("zh", "选择区域", "在任意显示器上选择需要遮挡的区域。") ] {
            for width in [300.0, 380.0] {
                _ = try render(RuleActionTile(title: title, detail: detail, icon: "crop", action: {})
                    .padding(12).background(RulePalette.background),
                    size: CGSize(width: width, height: 150), name: "region-\(language)-\(Int(width))")
            }
        }
    }

    @MainActor func testPermissionAndChoiceControlsRenderWithoutDesktopInteraction() throws {
        let view = VStack(spacing: 16) {
            RuleSettingRow(title: "Screen Recording", detail: "Permission needed", warning: true) {
                Button("Grant access") {}
            }
            RuleChoiceField(title: "Protect", selection: .constant(0), options: [(0, "Select region"), (1, "All displays")])
        }.padding(22).background(RulePalette.card).foregroundStyle(RulePalette.text)
            .buttonStyle(RuleButtonStyle())
        _ = try render(view, size: CGSize(width: 620, height: 180), name: "permission-and-region-choice")
    }

    func testWorkspaceKeepsTheThreeNavigationDestinations() {
        XCTAssertEqual(RuleWorkspacePage.allCases.map(\.rawValue), ["Protection", "Rules", "Settings"])
        XCTAssertEqual(Set(RuleWorkspacePage.allCases.map(\.title)).count, 3)
    }

    @MainActor func testRegionMarkerGeometryDoesNotNeedASelectionPanel() throws {
        let display = ProtectionDisplay(id: 202, frame: CGRect(x: -400, y: 100, width: 400, height: 300))
        let selection = SelectedDisplayRegion(displayID: 202, normalizedRect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
        XCTAssertEqual(RuleRegionMarker.frame(selection, display: display), CGRect(x: -300, y: 160, width: 200, height: 180))
        XCTAssertNil(RuleRegionMarker.frame(selection, display: ProtectionDisplay(id: 101, frame: display.frame)))
    }
}
