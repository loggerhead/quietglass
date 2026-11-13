import XCTest
import ScreenCaptureKit
@testable import QuietGlass

final class ScreenPermissionVerifierTests: XCTestCase {
    @MainActor func testChecksCanRunAgainAfterCompletionButNotConcurrently() async {
        var calls = 0
        let verifier = ScreenPermissionVerifier(check: { calls += 1; return true })
        let first = expectation(description: "First verification")
        verifier.start { result in XCTAssertEqual(result, true); first.fulfill() }
        verifier.start { _ in XCTFail("Duplicate concurrent check") }
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(calls, 1)
        let next = expectation(description: "Fresh verification")
        verifier.start { result in XCTAssertEqual(result, true); next.fulfill() }
        await fulfillment(of: [next], timeout: 1)
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testPermissionDenialIsDifferentFromAnUnrelatedServiceFailure() async {
        let denied = ScreenPermissionVerifier(check: {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        })
        let denial = expectation(description: "Authorization denied")
        denied.start { result in XCTAssertEqual(result, false); denial.fulfill() }
        await fulfillment(of: [denial], timeout: 1)
        let unavailable = ScreenPermissionVerifier(check: { throw NSError(domain: "Service unavailable", code: 1) })
        let failure = expectation(description: "Unknown, not denied")
        unavailable.start { result in XCTAssertNil(result); failure.fulfill() }
        await fulfillment(of: [failure], timeout: 1)
    }

    @MainActor func testCancelledLateResultCannotReplaceANewerVerification() async {
        var continuation: CheckedContinuation<Bool, Never>?
        var calls = 0
        let verifier = ScreenPermissionVerifier(check: {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { continuation = $0 } }
            return true
        })
        let obsolete = expectation(description: "Cancelled result ignored")
        obsolete.isInverted = true
        verifier.start { _ in obsolete.fulfill() }
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        verifier.cancel()
        let current = expectation(description: "Current check succeeds")
        verifier.start { result in XCTAssertEqual(result, true); current.fulfill() }
        continuation?.resume(returning: false)
        await fulfillment(of: [current, obsolete], timeout: 0.2)
    }
}
