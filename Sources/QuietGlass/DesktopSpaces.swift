import AppKit
import CoreGraphics
import Foundation
import ShieldCore

/// Reads the Mission Control Desktop (Space) currently shown on each display.
/// macOS has no public per-display Space API, so this uses SkyLight's
/// CGSCopyManagedDisplaySpaces. An empty result means the system could not be
/// queried; desktop-bound rules then stay conservative instead of exposing.
enum DesktopSpaces {
    /// The current Desktop for every online display, keyed by CGDirectDisplayID.
    static func current() -> [UInt32: DesktopSpace] {
        guard let entries = managedDisplaySpaces() else { return [:] }
        let identifiers = displayIdentifiers()
        var result: [UInt32: DesktopSpace] = [:]
        for entry in entries {
            guard let identifier = entry["Display Identifier"] as? String,
                  let displayID = identifiers[identifier],
                  let current = entry["Current Space"] as? [String: Any],
                  let spaceID = managedSpaceID(of: current),
                  let spaces = entry["Spaces"] as? [[String: Any]],
                  let index = spaces.firstIndex(where: { managedSpaceID(of: $0) == spaceID }) else { continue }
            result[displayID] = DesktopSpace(id: spaceID, number: index + 1)
        }
        return result
    }

    /// The current user-visible Desktop number for a saved Space, if it still exists.
    static func number(of spaceID: UInt64, on displayID: UInt32) -> Int? {
        guard let entries = managedDisplaySpaces(), let identifier = displayIdentifier(for: displayID),
              let entry = entries.first(where: { ($0["Display Identifier"] as? String) == identifier }),
              let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
        return spaces.firstIndex { managedSpaceID(of: $0) == spaceID }.map { $0 + 1 }
    }

    private static func managedSpaceID(of entry: [String: Any]) -> UInt64? {
        (entry["id64"] as? NSNumber)?.uint64Value ?? (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    private static func displayIdentifiers() -> [String: UInt32] {
        var values = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(values.count), &values, &count) == .success else { return [:] }
        var result: [String: UInt32] = [:]
        for id in values.prefix(Int(count)) {
            if let identifier = displayIdentifier(for: id) { result[identifier] = id }
        }
        return result
    }

    private static func displayIdentifier(for displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func managedDisplaySpaces() -> [[String: Any]]? {
        guard let handle = skyLight,
              let mainConnection = dlsym(handle, "CGSMainConnectionID"),
              let copySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(mainConnection, to: MainConnection.self)()
        return unsafeBitCast(copySpaces, to: CopyManagedDisplaySpaces.self)(connection)?.takeRetainedValue() as? [[String: Any]]
    }

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
}

private typealias MainConnection = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
