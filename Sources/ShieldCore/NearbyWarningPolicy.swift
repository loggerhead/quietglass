import Foundation

/// Legacy minute-based delay normalization is shared by migration and action
/// defaults. Warning state and deadlines are owned only by ProtectionEngine.
public enum NearbyWarningPolicy {
    public static let defaultDelay: TimeInterval = 120
    public static let maximumDelay: TimeInterval = 24 * 60 * 60
    public static func normalizedDelay(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultDelay }
        return min(maximumDelay, max(60, (seconds / 60).rounded() * 60))
    }
}
