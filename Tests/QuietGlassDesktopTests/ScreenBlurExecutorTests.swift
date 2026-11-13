import XCTest
import AppKit
import ShieldCore
@testable import QuietGlass

final class ScreenBlurExecutorTests: OptInDesktopTestCase {
    @MainActor func testTextConfigurationCannotStartCaptureOutsideAnAuthorizedPlan() throws {
        _ = NSApplication.shared
        let executor = ScreenBlurExecutor()
        defer { executor.shutdown() }
        let text = ProtectionPreset.sensitiveText.rule()
        executor.configureTextRules([text])
        var engine = try ProtectionEngine(rules: [text])
        executor.apply(engine.send(.tick, at: 0))
        XCTAssertFalse(executor.isCapturing)
        XCTAssertTrue(executor.captures.isEmpty)
        XCTAssertTrue(executor.fullSurfaces.values.allSatisfy { !$0.panel.isVisible })
        executor.apply(engine.send(.suspend, at: 1))
        XCTAssertFalse(executor.isCapturing)
        executor.apply(engine.send(.escape, at: 2))
        XCTAssertFalse(executor.isCapturing)
    }
}
