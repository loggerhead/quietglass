import XCTest
@testable import ShieldCore

final class ShortcutRegistryTests: XCTestCase {
    func testDetectsCollisionEvenWhenLabelsDifferAndIncludesPeek() {
        let binding = ShortcutBinding(keyCode: 35, modifiers: 6400, label: "First")
        let manual = ProtectionRule(name: "First", trigger: .manual(shortcut: binding), scope: .allDisplays)
        let second = ProtectionRule(name: "Second", trigger: .manual(shortcut: nil), scope: .allDisplays,
            action: .blur(BlurParameters(), peek: .hold(ShortcutBinding(keyCode: 35, modifiers: 6400, label: "Different label"))))
        let registry = ShortcutRegistry(rules: [manual, second], recenter: binding)
        XCTAssertFalse(registry.isValid); XCTAssertEqual(registry.conflicts.count, 1)
        XCTAssertEqual(registry.recenterConflicts.count, 2)
        XCTAssertEqual(registry.conflicts.first?.second.operation, .peek)
    }
    func testDisabledRulesDoNotReserveKeysAndChangingModifiersAvoidsCollision() {
        let binding = ShortcutBinding(keyCode: 35, modifiers: 6400, label: "First")
        let manual = ProtectionRule(name: "First", trigger: .manual(shortcut: binding), scope: .allDisplays)
        var second = manual
        second = ProtectionRule(name: "Second", isEnabled: false, trigger: .manual(shortcut: binding), scope: .allDisplays)
        XCTAssertTrue(ShortcutRegistry(rules: [manual, second]).isValid)
        second.isEnabled = true; second.trigger = .manual(shortcut: ShortcutBinding(keyCode: 35, modifiers: 256, label: "Second"))
        XCTAssertTrue(ShortcutRegistry(rules: [manual, second]).isValid)
    }
}
