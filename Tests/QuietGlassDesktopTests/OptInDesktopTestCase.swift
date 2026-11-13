import XCTest
import Foundation

/// Reject accidental execution before any test can create a window or hotkey.
class OptInDesktopTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["QUIETGLASS_TEST_DESKTOP"].map({ ["isolated", "interactive"].contains($0) }) == true else {
            throw IsolationRequired()
        }
    }

    private struct IsolationRequired: Error, CustomStringConvertible {
        var description: String {
            "Desktop tests require explicit opt-in. Use scripts/test-desktop.sh --interactive for this Mac, or --isolated in a dedicated session."
        }
    }
}
