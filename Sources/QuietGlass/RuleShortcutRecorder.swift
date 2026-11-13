import AppKit
import Carbon
import SwiftUI
import ShieldCore

extension ShortcutBinding {
    static func recorded(from event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode != 53, !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0, label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? QG("Key %ld", Int(event.keyCode))
        return ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}

@MainActor
struct RuleShortcutRecorder: View {
    @ObservedObject var model: AppModel
    @Binding var binding: ShortcutBinding?
    @State private var monitor: Any?
    @State private var recording = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(QG(recording ? "Press shortcut…" : binding?.label ?? "Set shortcut…")) { if recording { stop() } else { start() } }
                if binding != nil && !recording { Button(QG("Clear shortcut")) { binding = nil } }
            }
            if recording { Text(QG("Include Command, Control, or Option. Escape cancels recording and clears protection.")).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(QG(error)).font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: model.recordingRuleShortcut) { _, active in if !active && recording { stop() } }
        .onDisappear(perform: stop)
    }
    private func start() {
        error = nil; recording = true; model.recordingRuleShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); model.dismissShield(); return nil }
            guard let value = ShortcutBinding.recorded(from: event) else {
                error = "Include Command, Control, or Option in your shortcut."; return nil
            }
            stop(); binding = value
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false
        if model.recordingRuleShortcut { model.recordingRuleShortcut = false }
    }
}
