// Clinton Imaro was here 20/09/2026.

import SwiftUI

enum NotchMenuAction: CaseIterable {
    case snooze, controls, protection, rules, settings, resetPosition, screen, area, window, focus, pause, resume, clear
}

final class NotchMenuState: ObservableObject {
    @Published var highlighted: NotchMenuAction?
}

struct NotchContextMenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchMenuState
    let action: (NotchMenuAction) -> Void

    var body: some View {
        VStack(spacing: 2) {
            row(.controls, "Current protection", .controls)
            row(.protection, "Screen controls", .view)
            row(.rules, "Auto & shortcuts", .controls)
            row(.settings, "Settings", .settings)
            separator
            row(.screen, "Blur screen now", .viewOff)
            row(.area, "Select an area", .area)
            row(.window, "Protect a window", .viewOff)
            row(.focus, "Focus", .focus)
            separator
            row(.pause, "Pause", .pause)
            row(.resume, "Resume", .play)
            row(.clear, "Clear all · Escape", .cancel)
            separator
            row(.snooze, "Hide for 1 hour", .clock)
            row(.resetPosition, "Move Notch Down", .dockBottom)
        }
        .padding(6)
        .frame(width: 252)
        .background(Color(white: 0.985), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.14), lineWidth: 0.75))
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.light)
    }

    private var separator: some View {
        Rectangle().fill(.black.opacity(0.09)).frame(height: 1)
            .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func row(_ item: NotchMenuAction, _ title: String, _ icon: AppIcon,
                     shortcut: String? = nil, enabled: Bool = true) -> some View {
        let highlighted = enabled && state.highlighted == item
        return Button { action(item) } label: {
            HStack(spacing: 10) {
                AppIconView(icon: icon, size: 18)
                Text(QG(title))
                Spacer(minLength: 5)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.94, green: 0.68, blue: 0.91))
                        .opacity(enabled ? 1 : 0.5)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? Color.white : Color(white: 0.12).opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(QG(title))
        .onHover { inside in
            if inside, enabled { state.highlighted = item }
            else if state.highlighted == item { state.highlighted = nil }
        }
    }
}
