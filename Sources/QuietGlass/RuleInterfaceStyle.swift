import SwiftUI

enum RulePalette {
    static let background = Color(red: 17 / 255, green: 20 / 255, blue: 26 / 255)
    static let sidebar = Color(red: 23 / 255, green: 27 / 255, blue: 34 / 255)
    static let card = Color(red: 28 / 255, green: 32 / 255, blue: 40 / 255)
    static let border = Color.white.opacity(0.065)
    static let text = Color(red: 0.93, green: 0.94, blue: 0.97)
    static let secondary = Color(red: 0.61, green: 0.65, blue: 0.72)
    static let accent = Color(red: 0.88, green: 0.81, blue: 0.99)
}

struct RuleToggleStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                if showsLabel { configuration.label; Spacer(minLength: 12) }
                Capsule().fill(configuration.isOn ? RulePalette.accent : Color(white: 0.25))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Color(white: 0.12) : Color(white: 0.85)).frame(width: 18, height: 18).padding(2)
                    }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
            .accessibilityElement(children: .combine)
            .accessibilityValue(QG(configuration.isOn ? "On" : "Off"))
    }
}

struct RuleButtonStyle: ButtonStyle {
    enum Tone { case primary, secondary, quiet }
    var tone: Tone = .secondary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.role == .destructive && hovering ? Color.red : tone == .primary ? Color(white: 0.13) : RulePalette.text)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(tone == .primary ? RulePalette.accent : tone == .quiet ? Color.white.opacity(hovering ? 0.055 : 0) : Color.white.opacity(hovering ? 0.10 : 0.045),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tone == .secondary ? RulePalette.border : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

struct RuleDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(minHeight: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if configuration.isExpanded { configuration.content.padding(.leading, 18) }
        }
    }
}

struct RuleCard<Content: View>: View {
    let title: String
    let icon: String
    var surface = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RulePalette.accent)
                    .frame(width: 28, height: 28)
                    .background(RulePalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text(QG(title)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RulePalette.text).accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(surface ? 22 : 0).frame(maxWidth: .infinity, alignment: .leading)
        .background(surface ? RulePalette.card : .clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(surface ? RulePalette.border : .clear))
    }
}

struct RuleSettingRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    var warning = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(QG(title)).font(.system(size: 13, weight: .medium))
                    if warning { Circle().fill(Color.red).frame(width: 7, height: 7).accessibilityLabel(QG("Permission needed")) }
                }
                if let detail { Text(QG(detail)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content()
        }.padding(.vertical, 5)
    }
}

struct RuleActionTile: View {
    let title: String
    let detail: String
    let icon: String
    var selected = false
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: compact ? 15 : 18, weight: .regular))
                    .foregroundStyle(RulePalette.accent).frame(width: compact ? 32 : 42, height: compact ? 32 : 42)
                    .background(RulePalette.accent.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(QG(title)).font(.system(size: 13, weight: .semibold))
                    Text(QG(detail)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(RulePalette.accent) }
            }.padding(compact ? 14 : 18).frame(maxWidth: .infinity, minHeight: compact ? 76 : 96, alignment: .leading)
                .background(RulePalette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).fill(selected ? RulePalette.accent.opacity(0.07) : Color.white.opacity(hovering ? 0.045 : 0)).allowsHitTesting(false))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? RulePalette.accent.opacity(0.35) : Color.white.opacity(hovering ? 0.13 : 0.05)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// Draw the selection label in SwiftUI so menus match the cards and sheets.
struct RuleChoiceField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 20) {
            Text(QG(title)).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Button { expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Text(QG(options.first { $0.0 == selection }?.1 ?? title)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(RulePalette.secondary)
                }.frame(width: 250, alignment: .leading)
            }.accessibilityLabel(QG(title))
                .popover(isPresented: $expanded, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(options, id: \.0) { option in
                            Button {
                                expanded = false
                                selection = option.0
                            } label: {
                                HStack {
                                    Text(QG(option.1))
                                    Spacer(minLength: 12)
                                    if selection == option.0 { Image(systemName: "checkmark").foregroundStyle(RulePalette.accent) }
                                }.padding(10).frame(width: 270, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(6).font(.system(size: 13)).foregroundStyle(RulePalette.text)
                        .background(RulePalette.card).preferredColorScheme(.dark)
                }
        }
    }
}
