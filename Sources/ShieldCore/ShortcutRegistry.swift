import Foundation

public struct RuleShortcut: Equatable {
    public enum Operation: Equatable { case activate, peek }
    public let ruleID: UUID
    public let binding: ShortcutBinding
    public let operation: Operation
}
public struct ShortcutConflict: Equatable {
    public let first: RuleShortcut
    public let second: RuleShortcut
}

/// The platform adapter registers this list with Carbon. Matching uses key/modifier
/// codes, never the editable display label. Recenter is an infrastructure shortcut.
public struct ShortcutRegistry {
    public let bindings: [RuleShortcut]
    public let conflicts: [ShortcutConflict]
    public let recenterConflicts: [RuleShortcut]
    public var isValid: Bool { conflicts.isEmpty && recenterConflicts.isEmpty }
    public init(rules: [ProtectionRule], recenter: ShortcutBinding? = nil) {
        var bindings: [RuleShortcut] = []
        for rule in rules where rule.isEnabled {
            guard case .manual(let shortcut) = rule.trigger else { continue }
            if let shortcut { bindings.append(RuleShortcut(ruleID: rule.id, binding: shortcut, operation: .activate)) }
            if case .blur(_, .hold(let shortcut)) = rule.action {
                bindings.append(RuleShortcut(ruleID: rule.id, binding: shortcut, operation: .peek))
            }
        }
        self.bindings = bindings
        var conflicts: [ShortcutConflict] = []
        for index in bindings.indices {
            for other in bindings.indices where other > index && Self.matches(bindings[index].binding, bindings[other].binding) {
                conflicts.append(ShortcutConflict(first: bindings[index], second: bindings[other]))
            }
        }
        self.conflicts = conflicts
        recenterConflicts = recenter.map { recenter in bindings.filter { Self.matches($0.binding, recenter) } } ?? []
    }
    private static func matches(_ a: ShortcutBinding, _ b: ShortcutBinding) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }
}
