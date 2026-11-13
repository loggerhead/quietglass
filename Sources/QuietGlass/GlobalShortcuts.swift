// Clinton Imaro was here 20/09/2026.

import AppKit
import Carbon
import ShieldCore

final class GlobalShortcuts {
    var onRecenter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onRule: ((RuleShortcut, Bool) -> Void)?
    private var onRegionSelection: (() -> Void)?
    private var regionSelectionBinding: ShortcutBinding?
    private var regionSelectionRef: EventHotKeyRef?
    private var ruleRefs: [UInt32: EventHotKeyRef] = [:]
    private var ruleBindings: [UInt32: RuleShortcut] = [:]
    private var ruleHotkeyIDs: [String: UInt32] = [:]
    private var nextRuleHotkeyID: UInt32 = 100
    private var recenterRef: EventHotKeyRef?
    private var recenterBinding: ShortcutBinding?
    private var escapeRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x51474C53

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == kEventHotKeyPressed
            if let binding = owner.ruleBindings[identifier.id] { owner.dispatchRule(binding, pressed: pressed); return noErr }
            if pressed, identifier.id == 3 { owner.onRegionSelection?(); return noErr }
            if pressed, identifier.id == 1 { owner.onRecenter?() }
            if pressed, identifier.id == 2 { owner.onEscape?() }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Borrow a rule chord while editing, or register a temporary chord.
    /// This editor-only lease does not change rules or preferences.
    func beginRegionSelection(_ candidates: [ShortcutBinding], action: @escaping () -> Void) -> ShortcutBinding? {
        endRegionSelection()
        for binding in candidates {
            if let recenterBinding, Self.matches(binding, recenterBinding) { continue }
            if ruleBindings.values.contains(where: { $0.operation == .peek && Self.matches($0.binding, binding) }) { continue }
            regionSelectionBinding = binding; onRegionSelection = action
            if registerRegionSelection() { return binding }
        }
        endRegionSelection()
        return nil
    }
    func endRegionSelection() {
        if let regionSelectionRef { UnregisterEventHotKey(regionSelectionRef) }
        regionSelectionRef = nil; regionSelectionBinding = nil; onRegionSelection = nil
    }
    func dispatchRule(_ binding: RuleShortcut, pressed: Bool) {
        if let regionSelectionBinding, Self.matches(binding.binding, regionSelectionBinding) {
            if pressed { onRegionSelection?() }
        } else { onRule?(binding, pressed) }
    }
    private static func matches(_ first: ShortcutBinding, _ second: ShortcutBinding) -> Bool {
        first.keyCode == second.keyCode && first.modifiers == second.modifiers
    }
    private func registerRegionSelection() -> Bool {
        guard let binding = regionSelectionBinding else { return true }
        if ruleBindings.values.contains(where: { Self.matches($0.binding, binding) }) { return true }
        return RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: signature, id: 3),
                                   GetApplicationEventTarget(), 0, &regionSelectionRef) == noErr
    }

    @discardableResult
    func armEscape(_ active: Bool) -> Bool {
        if active && escapeRef == nil {
            return RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &escapeRef) == noErr
        } else if !active, let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
        return true
    }

    @discardableResult func configureRules(_ registry: ShortcutRegistry, recenter: ShortcutBinding? = nil, activeManualRules: Set<UUID>? = nil) -> Bool {
        guard registry.isValid else { return false }
        var entries: [UInt32: RuleShortcut] = [:]
        for binding in registry.bindings {
            if binding.operation == .peek, let activeManualRules, !activeManualRules.contains(binding.ruleID) { continue }
            let key = binding.ruleID.uuidString + (binding.operation == .peek ? ":peek" : ":activate")
            let id: UInt32
            if let existing = ruleHotkeyIDs[key] { id = existing }
            else { id = nextRuleHotkeyID; nextRuleHotkeyID += 1; ruleHotkeyIDs[key] = id }
            entries[id] = binding
        }
        let sameRecenter = recenterBinding?.keyCode == recenter?.keyCode && recenterBinding?.modifiers == recenter?.modifiers
        if ruleBindings == entries && sameRecenter { return true }
        if let regionSelectionRef { UnregisterEventHotKey(regionSelectionRef); self.regionSelectionRef = nil }
        defer { _ = registerRegionSelection() }
        let previous = ruleBindings
        let previousRecenter = recenterBinding
        if let recenterRef { UnregisterEventHotKey(recenterRef); self.recenterRef = nil }
        recenterBinding = nil
        for ref in ruleRefs.values { UnregisterEventHotKey(ref) }; ruleRefs = [:]; ruleBindings = [:]
        func register(_ entries: [UInt32: RuleShortcut], recenter: ShortcutBinding?) -> Bool {
            var success = true
            if let recenter {
                var ref: EventHotKeyRef?
                if RegisterEventHotKey(recenter.keyCode, recenter.modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr {
                    recenterRef = ref; recenterBinding = recenter
                } else { success = false }
            }
            for (id, entry) in entries.sorted(by: { $0.key < $1.key }) {
                var ref: EventHotKeyRef?
                let result = RegisterEventHotKey(entry.binding.keyCode, entry.binding.modifiers,
                    EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
                if result == noErr, let ref { ruleRefs[id] = ref; ruleBindings[id] = entry } else { success = false }
            }
            return success
        }
        if register(entries, recenter: recenter) { return true }
        for ref in ruleRefs.values { UnregisterEventHotKey(ref) }; ruleRefs = [:]; ruleBindings = [:]
        if let recenterRef { UnregisterEventHotKey(recenterRef); self.recenterRef = nil }
        recenterBinding = nil
        _ = register(previous, recenter: previousRecenter)
        return false
    }
    func suspendRuleRecording() {
        endRegionSelection()
        for ref in ruleRefs.values { UnregisterEventHotKey(ref) }; ruleRefs = [:]; ruleBindings = [:]
        if let recenterRef { UnregisterEventHotKey(recenterRef); self.recenterRef = nil }
        recenterBinding = nil
    }

    deinit {
        if let regionSelectionRef { UnregisterEventHotKey(regionSelectionRef) }
        for ref in ruleRefs.values { UnregisterEventHotKey(ref) }
        if let recenterRef { UnregisterEventHotKey(recenterRef) }
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        if let handler { RemoveEventHandler(handler) }
    }
}
