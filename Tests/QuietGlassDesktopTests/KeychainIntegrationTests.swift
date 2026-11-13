import XCTest
import Security
import LocalAuthentication
import ShieldCore
@testable import QuietGlass

final class KeychainIntegrationTests: OptInDesktopTestCase {
    func testRealKeychainRoundTripInAnIsolatedTemporaryKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuietGlass-Keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let status = password.withCString { pointer in
            SecKeychainCreate(directory.appendingPathComponent("test.keychain-db").path, UInt32(password.utf8.count), pointer, false, nil, &keychain)
        }
        XCTAssertEqual(status, errSecSuccess)
        let isolated = try XCTUnwrap(keychain)
        defer { SecKeychainDelete(isolated) }
        let store = OwnerTemplateStore(keychain: isolated)
        let vector: [Float] = [1] + Array(repeating: 0, count: 127)
        let original = OwnerTemplate(vectors: Array(repeating: vector, count: 5), openEyes: 0.3)
        XCTAssertFalse(store.containsTemplate)
        try store.write(original, context: LAContext())
        XCTAssertTrue(store.containsTemplate)
        XCTAssertEqual(try store.read(context: LAContext()), original)
        let replacement = OwnerTemplate(vectors: Array(repeating: vector, count: 5), openEyes: 0.28)
        try store.write(replacement, context: LAContext())
        XCTAssertEqual(try store.read(context: LAContext()), replacement)
        XCTAssertThrowsError(try store.write(OwnerTemplate(vectors: [], openEyes: 0.3), context: LAContext()))
        XCTAssertEqual(try store.read(context: LAContext()), replacement)
        try store.delete(context: LAContext())
        XCTAssertFalse(store.containsTemplate)
        XCTAssertThrowsError(try store.read(context: LAContext()))
    }
}
