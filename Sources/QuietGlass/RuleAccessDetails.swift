import SwiftUI
import ShieldCore

/// Readable status rows rather than disabled menu items that look like failures.
struct RuleAccessDetails: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ProtectionCoordinator
    let rule: ProtectionRule
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
        }.buttonStyle(.plain).help(QG("Requirements and access")).accessibilityLabel(QG("Requirements and access"))
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(QG("Requirements and access")).font(.system(size: 13, weight: .semibold))
                    ForEach([PermissionKind.screen, .camera, .motion].filter(rule.requiredPermissions.contains), id: \.self) { kind in
                        if kind == .screen && model.rulePermissions.screenCheckPending {
                            HStack {
                                Text(QG(kind.accessTitle)).font(.system(size: 12))
                                Spacer()
                                Text(QG("Checking access…")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                            }
                        } else if kind == .screen && model.rulePermissions.screenCheckUnavailable && !model.screenPermission {
                            Text(QG("Could not verify screen access")).font(.system(size: 12)).foregroundStyle(.orange)
                        } else {
                            statusRow(kind.accessTitle, granted: model.permissionGranted(kind), success: "Granted", failure: "Not granted")
                        }
                    }
                    if rule.requiredPermissions.contains(.screen) && model.screenCaptureNeedsRestart {
                        Text(QG("Screen Recording is granted, but the capture session was rejected. Restart QuietGlass to apply access to this session."))
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(rule.guards.enumerated()), id: \.offset) { _, condition in
                        switch condition {
                        case .permission: EmptyView()
                        case .notPaused:
                            statusRow("While protection is running", granted: coordinator.plan.state == .running, success: "Running", failure: "Not running")
                        default:
                            Text(QG(condition.title)).font(.system(size: 12)).foregroundStyle(RulePalette.text)
                        }
                    }
                    Text(QG("These are the setup’s requirements. Permission status reflects the current system access."))
                        .font(.system(size: 11)).foregroundStyle(RulePalette.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(width: 310).foregroundStyle(RulePalette.text)
                    .background(RulePalette.card).preferredColorScheme(.dark)
            }
    }

    private func statusRow(_ title: String, granted: Bool, success: String, failure: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(QG(title)).font(.system(size: 12))
            Spacer(minLength: 8)
            Text(QG(granted ? success : failure)).font(.system(size: 11))
                .foregroundStyle(granted ? .green : .red)
        }.accessibilityElement(children: .combine)
    }
}
