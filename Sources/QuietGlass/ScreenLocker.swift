import Foundation

/// Locks the current macOS session. macOS has no public lock API, so this uses
/// the login framework's SACLockScreenImmediate symbol. The symbol is resolved
/// once and kept for the process lifetime.
enum ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockFunction: LockFunction? = {
        let candidates = [
            "/System/Library/PrivateFrameworks/login.framework/login",
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            "/System/Library/PrivateFrameworks/LoginUIKit.framework/LoginUIKit"
        ]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW) else { continue }
            if let symbol = dlsym(handle, "SACLockScreenImmediate") {
                return unsafeBitCast(symbol, to: LockFunction.self)
            }
        }
        return nil
    }()

    /// Returns false when the system does not expose the lock API.
    @discardableResult
    static func lock() -> Bool {
        guard let lockFunction else {
            NSLog("QuietGlass: the system lock-screen API is unavailable.")
            return false
        }
        return lockFunction() == 0
    }
}
