import AppKit
import XCTest
import ShieldCore
@testable import QuietGlass

final class RuleRegionSelectionTests: OptInDesktopTestCase {
    @MainActor func testSelectedRegionMarkerUsesDisplayCoordinatesAndDoesNotInterceptClicks() throws {
        _ = NSApplication.shared
        let marker = RuleRegionMarker(); defer { marker.close() }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = try XCTUnwrap((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        let selection = SelectedDisplayRegion(displayID: id, normalizedRect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4))
        marker.show(selection)
        let panel = try XCTUnwrap(NSApp.windows.first { String(describing: type(of: $0)).contains("RuleRegionMarkerPanel") && $0.isVisible })
        let expected = try XCTUnwrap(RuleRegionMarker.frame(selection, display: ProtectionDisplay(id: id, frame: screen.frame)))
        // AppKit rounds panel edges to screen pixels.
        XCTAssertEqual(panel.frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, expected.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, expected.maxY, accuracy: 1)
        XCTAssertTrue(panel.ignoresMouseEvents); XCTAssertFalse(panel.canBecomeKey); XCTAssertEqual(panel.sharingType, .none)
        marker.close(); XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testDragOnSecondDisplayReturnsItsNormalizedRegionAndClosesAllPanels() throws {
        _ = NSApplication.shared
        let selector = AreaSelectionController()
        defer { selector.close() }
        let displays = [ProtectionDisplay(id: 101, frame: CGRect(x: 100, y: 100, width: 640, height: 400)),
                        ProtectionDisplay(id: 202, frame: CGRect(x: -400, y: 100, width: 400, height: 300))]
        var result: SelectedDisplayRegion?
        selector.show(displays: displays) { result = $0 }
        let panels = NSApp.windows.compactMap { $0 as? AreaSelectionPanel }.filter(\.isVisible)
        XCTAssertEqual(panels.count, 2)
        let target = try XCTUnwrap(panels.first { $0.frame == displays[1].frame })
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 300, y: 240)),
                              (.leftMouseDragged, CGPoint(x: 100, y: 60)), (.leftMouseUp, CGPoint(x: 100, y: 60))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            target.sendEvent(event)
        }
        XCTAssertEqual(result, SelectedDisplayRegion(displayID: 202, normalizedRect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)))
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
    }

    @MainActor func testEscapeCancelsSelectionWithoutDeliveringAnArea() throws {
        _ = NSApplication.shared
        let selector = AreaSelectionController(); defer { selector.close() }
        var selections = 0
        selector.show(displays: [ProtectionDisplay(id: 1, frame: CGRect(x: 100, y: 100, width: 400, height: 300))]) { _ in selections += 1 }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? AreaSelectionPanel }.first { $0.isVisible })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(event)
        XCTAssertEqual(selections, 0)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testEditorBorrowsAreaShortcutAndRestoresItsRuleDispatch() throws {
        let shortcuts = GlobalShortcuts(); defer { shortcuts.endRegionSelection() }
        let binding = ShortcutBinding(keyCode: 80, modifiers: 6912, label: "⌃⌥⇧⌘F19")
        let rule = ProtectionRule(name: "Area", trigger: .manual(shortcut: binding), scope: .allDisplays)
        let registry = ShortcutRegistry(rules: [rule])
        XCTAssertTrue(shortcuts.configureRules(registry))
        let entry = try XCTUnwrap(registry.bindings.first)
        var selections = 0, ruleEvents = 0
        shortcuts.onRule = { _, _ in ruleEvents += 1 }
        var alias = binding; alias.label = "Different display label"
        XCTAssertEqual(shortcuts.beginRegionSelection([alias]) { selections += 1 }, alias)
        shortcuts.dispatchRule(entry, pressed: true); shortcuts.dispatchRule(entry, pressed: false)
        XCTAssertEqual(selections, 1); XCTAssertEqual(ruleEvents, 0)
        shortcuts.endRegionSelection()
        shortcuts.dispatchRule(entry, pressed: true)
        XCTAssertEqual(ruleEvents, 1)
    }

    @MainActor func testTemporaryShortcutRejectsOccupiedChordAndIsReleasedAfterEditing() {
        let first = GlobalShortcuts(), second = GlobalShortcuts()
        defer { first.endRegionSelection(); second.endRegionSelection() }
        let chord = ShortcutBinding(keyCode: 80, modifiers: 6912, label: "⌃⌥⇧⌘F19")
        let fallback = ShortcutBinding(keyCode: 79, modifiers: 6912, label: "⌃⌥⇧⌘F18")
        XCTAssertEqual(first.beginRegionSelection([chord], action: {}), chord)
        XCTAssertEqual(second.beginRegionSelection([chord, fallback], action: {}), fallback)
        first.endRegionSelection(); second.endRegionSelection()
        XCTAssertEqual(second.beginRegionSelection([chord], action: {}), chord)
    }
}
