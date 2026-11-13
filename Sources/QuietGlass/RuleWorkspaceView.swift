import AppKit
import SwiftUI
import ShieldCore

enum RuleWorkspacePage: String, CaseIterable, Identifiable {
    case protection = "Protection", rules = "Rules", settings = "Settings"
    var id: Self { self }
    var title: String { switch self { case .protection: return "Screen controls"; case .rules: return "Auto & shortcuts"; case .settings: return "Settings" } }
    var detail: String { switch self { case .protection: return "Hide content by hand"; case .rules: return "Choose when to respond"; case .settings: return "Devices and preferences" } }
    var symbol: String { switch self { case .protection: return "lock.shield"; case .rules: return "list.bullet.rectangle"; case .settings: return "gearshape" } }
}
@MainActor final class RuleNavigationState: ObservableObject {
    @Published var page: RuleWorkspacePage = .protection
    @Published var triggerFilter: RuleTriggerKind?
    @Published var sidebarToggle = 0
    @Published var bottomInset: CGFloat = 0
}

struct RuleEditorSession: Identifiable {
    let id = UUID()
    let rule: ProtectionRule?
}

@MainActor
struct RuleWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ProtectionCoordinator
    @ObservedObject var navigation: RuleNavigationState
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var editorSession: RuleEditorSession?
    @State private var highlightedRuleID: UUID?
    @State private var presetFeedbackToken = 0
    @State private var presetNotice: String?
    @State private var ownerSetup = false
    @State private var cameraCheck = false
    @State private var resumeAfterOwner = false
    @State private var message: String?
    var body: some View {
        HStack(spacing: 0) {
            if columns == .all {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 16)).foregroundStyle(RulePalette.accent)
                            .frame(width: 32, height: 32).background(RulePalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        Text(QG("QuietGlass")).font(.system(size: 15, weight: .semibold))
                    }.padding(.horizontal, 12).padding(.bottom, 22)
                    ForEach(RuleWorkspacePage.allCases) { page in
                        Button { navigation.page = page } label: {
                            HStack(spacing: 12) {
                                Image(systemName: page.symbol).font(.system(size: 15, weight: .medium)).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(QG(page.title)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(QG(page.detail)).font(.system(size: 10)).foregroundStyle(RulePalette.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                                .foregroundStyle(navigation.page == page ? RulePalette.text : RulePalette.secondary)
                                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
                                .background(navigation.page == page ? RulePalette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(alignment: .trailing) {
                                    if navigation.page == page { RoundedRectangle(cornerRadius: 2).fill(RulePalette.accent).frame(width: 3, height: 18).padding(.trailing, 7) }
                                }.contentShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityIdentifier("navigation." + page.rawValue.lowercased())
                    }
                    Spacer()
                    Label(QG("Private by design"), systemImage: "checkmark.shield")
                        .font(.system(size: 12)).foregroundStyle(RulePalette.secondary).padding(12)
                }.padding(14).padding(.top, 38).frame(maxHeight: .infinity)
                    .background(RulePalette.sidebar).frame(width: 224)
                    .overlay(alignment: .trailing) { Rectangle().fill(RulePalette.border).frame(width: 1) }
            }
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(QG(navigation.page.title)).font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text(QG(pageSubtitle)).font(.system(size: 13)).foregroundStyle(RulePalette.secondary)
                    }.padding(.bottom, 6)
                    switch navigation.page { case .protection: protection; case .rules: rules; case .settings: settings }
                    if let message { Text(QG(message)).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 30).padding(.top, 38)
                    .padding(.bottom, 32 + navigation.bottomInset).frame(maxWidth: .infinity, alignment: .top)
            }.background(RulePalette.background)
                .onChange(of: presetFeedbackToken) { _, _ in
                    if let highlightedRuleID { withAnimation { scroll.scrollTo(highlightedRuleID, anchor: .center) } }
                }
            }
        }
        .font(.system(size: 13)).foregroundStyle(RulePalette.text).tint(RulePalette.accent)
        .preferredColorScheme(.dark).buttonStyle(RuleButtonStyle())
        .disclosureGroupStyle(RuleDisclosureStyle())
        .toggleStyle(RuleToggleStyle())
        .onChange(of: navigation.sidebarToggle) { _, _ in columns = columns == .all ? .detailOnly : .all }
        .sheet(item: $editorSession) { session in RuleEditorView(model: model, coordinator: coordinator, rule: session.rule).id(session.id) }
        .sheet(isPresented: $ownerSetup) {
            OwnerEnrollmentView(owner: model.nearby.owner).onDisappear { if resumeAfterOwner { coordinator.resume() } }
        }
        .sheet(isPresented: $cameraCheck) {
            ProtectionCheckView(check: model.protectionCheck, cameraID: model.nearby.selectedCameraID,
                                response: model.nearby.response, canBlur: model.screenPermission)
        }
        .accessibilityIdentifier("rule.workspace")
    }
    private var pageSubtitle: String {
        switch navigation.page {
        case .protection: return "Hide screen content now, see what is hidden, or pause and resume."
        case .rules: return "Set up automatic responses and actions you can use by hand."
        case .settings: return "Manage permissions, calibrate devices, and adjust preferences."
        }
    }
    private var protectionHeading: String {
        if coordinator.plan.hasProtection { return "Screen content is being hidden" }
        if !coordinator.plan.warnings.isEmpty { return "A warning needs your attention" }
        switch coordinator.plan.state {
        case .paused: return "All protection is paused"
        case .cleared: return "Current protection has been cleared"
        case .suspended: return "Protection is waiting for your Mac"
        case .running: return "No screen content is hidden"
        }
    }
    private var protectionExplanation: String {
        if coordinator.plan.hasProtection { return "The active setups and affected displays are listed below." }
        if !coordinator.plan.warnings.isEmpty { return "Check the warning below. You can choose to hide content now." }
        switch coordinator.plan.state {
        case .paused: return "Resume to continue the setups you have enabled."
        case .cleared: return "Use a manual action below, or resume your enabled setups."
        case .suspended: return "Protection will continue after your Mac wakes or your session returns."
        case .running: return "Use an action below to hide content now. Automatic setups respond when their conditions are met."
        }
    }
    private var protection: some View {
        VStack(alignment: .leading, spacing: 20) {
            RuleCard(title: "What is happening now", icon: "lock.shield") {
                HStack(spacing: 16) {
                    Image(systemName: coordinator.plan.hasProtection ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 27)).foregroundStyle(coordinator.plan.hasProtection ? .green : RulePalette.accent)
                        .frame(width: 56, height: 56).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(QG(protectionHeading)).font(.system(size: 19, weight: .semibold))
                        Text(QG(protectionExplanation)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !coordinator.plan.hasProtection && coordinator.plan.warnings.isEmpty && coordinator.plan.state == .running && model.headRulesEnabled {
                    Text(QG(model.status)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                }
                ForEach(coordinator.plan.activeRules) { active in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(RulePalette.accent).frame(width: 5, height: 5).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(QG(active.name)).font(.system(size: 13, weight: .medium))
                            Text(QG(active.reason.title)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                        }
                    }
                }
                ForEach(coordinator.plan.displays.filter(\.hasProtection), id: \.displayID) { display in
                    HStack {
                        Label(model.connectedDisplays.first { $0.id == display.displayID }?.name ?? QG("Display %ld", Int(display.displayID)), systemImage: "display")
                        Spacer()
                        if display.fullScreenCoverage > 0 { Text(QG("Coverage %ld%%", Int(display.fullScreenCoverage * 100))) }
                        else { Text(QG("%ld protected regions", display.regions.count + display.textRegions.count)) }
                    }.font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                }
                DisclosureGroup(QG("Rule details")) {
                    Text(QG(model.status)).font(.system(size: 11))
                    ForEach(coordinator.plan.activeRules) { active in
                        Text(QG("Rule ID: %@", active.id.uuidString)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }.font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                if let notice = model.privacy.notice { Text(QG(notice)).font(.caption).foregroundStyle(.orange) }
                if let notice = model.shortcutNotice { Text(QG(notice)).font(.caption).foregroundStyle(.orange) }
                if let notice = model.captureNotice { Text(QG(notice)).font(.caption).foregroundStyle(.orange) }
            }
            RuleCard(title: "Hide content by hand", icon: "bolt", surface: false) {
                Text(QG("Select the content you want to hide. Click the full-screen or focus action again to turn it off.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], spacing: 10) {
                    RuleActionTile(title: "Blur all displays", detail: "Hide content on every display; click again to remove this blur.", icon: "eye.slash", selected: model.privacy.instant) { model.toggleInstantShield() }
                    RuleActionTile(title: "Blur part of a window", detail: "Drag over an area inside your current window.", icon: "crop") { model.privacy.chooseArea() }
                    RuleActionTile(title: "Blur one window", detail: "Choose a window and hide its contents.", icon: "macwindow") { model.privacy.chooseWindow() }
                    RuleActionTile(title: "Focus on this window", detail: "Keep the current window clear and blur everything around it.", icon: "viewfinder", selected: model.privacy.focusEnabled) { model.setFocus(!model.privacy.focusEnabled) }
                }
            }
            if !coordinator.plan.warnings.isEmpty {
                RuleCard(title: "Needs your attention", icon: "exclamationmark.triangle") {
                    ForEach(coordinator.plan.warnings) { warning in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(QG(warning.rule.name)).font(.system(size: 13, weight: .medium))
                                Text(QG("%ld seconds remaining", warning.secondsRemaining)).font(.caption).foregroundStyle(RulePalette.secondary)
                            }
                            Spacer()
                            Button(QG("Blur now")) { coordinator.blurNow(warning.id) }.buttonStyle(RuleButtonStyle(tone: .primary))
                        }
                    }
                }
            }
            RuleCard(title: "Pause, resume, or clear", icon: "pause.circle", surface: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], spacing: 10) {
                    RuleActionTile(title: "Clear current protection · Escape", detail: "Remove current blur and temporarily stop automatic responses.", icon: "xmark.circle", compact: true) { model.dismissShield() }
                    RuleActionTile(title: "Pause all protection", detail: "Stop protection until you choose to resume.", icon: "pause.circle", compact: true) { coordinator.pause() }
                    RuleActionTile(title: "Pause for 5 minutes", detail: "Stop temporarily, then resume after five minutes.", icon: "clock", compact: true) { coordinator.pause(seconds: 300) }
                    RuleActionTile(title: "Resume protection", detail: "Continue working with the setups you have enabled.", icon: "play.circle", compact: true) { coordinator.resume() }
                }
            }
        }
    }
    private var rules: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let presetNotice { Label(presetNotice, systemImage: "checkmark.circle.fill").foregroundStyle(RulePalette.accent).font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RulePalette.card, in: RoundedRectangle(cornerRadius: 10)) }
            RuleCard(title: "Start with a ready-made setup", icon: "sparkles", surface: false) {
                Text(QG("Each card enables its saved setup and shows it below. Repeated clicks reuse the same setup and keep your edits.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], spacing: 10) {
                    ForEach(ProtectionPreset.allCases, id: \.rawValue) { preset in
                        RuleActionTile(title: preset.title, detail: preset.detail, icon: preset.symbol) {
                            activatePreset(preset)
                        }
                    }
                }
            }
            HStack {
                Text(QG("Your saved setups")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { editorSession = RuleEditorSession(rule: nil) } label: { Label(QG("New setup…"), systemImage: "plus") }
                    .buttonStyle(RuleButtonStyle(tone: .primary)).accessibilityIdentifier("rules.new")
            }
            Text(QG("The switch allows a setup to work. Automatic setups wait for their conditions; manual actions can be used with a button or shortcut.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            VStack(spacing: 0) {
                ForEach(Array(coordinator.document.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { Divider().overlay(RulePalette.border).padding(.horizontal, 16) }
                    ruleRow(rule)
                }
            }
            .background(RulePalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RulePalette.border))

        }
    }
    private func ruleRow(_ rule: ProtectionRule) -> some View {
        let missing = model.missingPermissions(for: rule)
        let trigger = RuleTriggerKind(rule.trigger)
        let badge = trigger == .manual ? QG("Manual") : QG("Auto · %@", QG(trigger.groupTitle))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(QG(rule.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(RulePalette.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RulePalette.accent.opacity(0.08), in: Capsule())
                if !missing.isEmpty {
                    Label(QG("Missing access: %@", model.rulePermissions.missingAccessTitle(missing)), systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(.red)
                } else if rule.requiredPermissions.contains(.screen) && model.rulePermissions.screenCheckPending {
                    Text(QG("Checking access…")).font(.system(size: 10)).foregroundStyle(RulePalette.secondary)
                } else if rule.requiredPermissions.contains(.screen) && model.rulePermissions.screenCheckUnavailable && !model.screenPermission {
                    Text(QG("Could not verify screen access")).font(.system(size: 10)).foregroundStyle(.orange)
                } else if rule.requiredPermissions.contains(.screen) && model.screenCaptureNeedsRestart {
                    Label(QG("Screen capture needs a restart"), systemImage: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(.orange)
                }
                if !rule.guards.isEmpty || !rule.requiredPermissions.isEmpty {
                    RuleAccessDetails(model: model, coordinator: coordinator, rule: rule)
                }
                Spacer(minLength: 0)
                Toggle(QG("Enabled"), isOn: Binding(get: { coordinator.document.rules.first { $0.id == rule.id }?.isEnabled ?? false },
                    set: { value in perform { try coordinator.setEnabled(rule.id, value) } }))
                    .toggleStyle(RuleToggleStyle(showsLabel: false)).labelsHidden().controlSize(.small).accessibilityLabel(QG(rule.name))
            }
            HStack(spacing: 6) {
                Text(QG("%@ · %@", rule.scopeTitle, rule.actionTitle)).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    .lineLimit(1).help(rule.responseExplanation).accessibilityHint(rule.responseExplanation)
                Spacer(minLength: 8)
                if !missing.isEmpty { Button(QG("Grant access")) { model.guideRulePermissions([rule], force: true) }.buttonStyle(RuleButtonStyle(tone: .quiet)) }
                if rule.requiredPermissions.contains(.screen) && model.rulePermissions.screenCheckUnavailable && !model.screenPermission {
                    Button(QG("Check again")) { model.verifyScreenPermission() }.buttonStyle(RuleButtonStyle(tone: .quiet))
                }
                if rule.requiredPermissions.contains(.screen) && model.screenCaptureNeedsRestart {
                    Button(QG("Restart QuietGlass")) { model.restartForScreenPermission() }.buttonStyle(RuleButtonStyle(tone: .quiet))
                }
                if case .manual = rule.trigger {
                    Button(QG(coordinator.isManuallyActivated(rule.id) ? "Stop" : "Use now")) { activate(rule) }.disabled(!rule.isEnabled)
                }
                Button(QG("Edit…")) { editorSession = RuleEditorSession(rule: rule) }.buttonStyle(RuleButtonStyle(tone: .quiet))
                Button(QG("Delete"), role: .destructive) { perform { try coordinator.remove(rule.id) } }.buttonStyle(RuleButtonStyle(tone: .quiet))
            }
            if case .manual = rule.trigger, case .region(_, _, .session) = rule.scope,
               let area = model.privacy.protectedAreas.first(where: { $0.id == rule.id }) {
                Button(QG("Remember matching title")) { model.privacy.rememberArea(area) }
            }
        }.padding(.vertical, 12).padding(.horizontal, 16)
            .background(highlightedRuleID == rule.id ? RulePalette.accent.opacity(0.08) : .clear)
            .id(rule.id).accessibilityIdentifier("rule." + rule.id.uuidString)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            permissions
            RuleCard(title: "General and appearance", icon: "slider.horizontal.3") {
                RuleSettingRow(title: "Launch at login") {
                    Toggle(QG("Launch at login"), isOn: Binding(get: { model.loginPreference.enabled }, set: { model.loginPreference.setEnabled($0) })).labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false)).controlSize(.small)
                }
                if model.loginPreference.needsApproval { Button(QG("Open Login Items")) { model.loginPreference.openSettings() } }
                Divider()
                RuleSettingRow(title: "Show blur in recordings", detail: "Include the protection effect when sharing or recording your screen.") {
                    Toggle(QG("Show blur in recordings"), isOn: $model.demoMode).labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false)).controlSize(.small)
                }
                Divider()
                BlurStrengthControl(strength: $model.blur, accent: RulePalette.accent)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(QG("Workspace presets")).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 8) { ForEach(PrivacyProfile.allCases) { profile in Button(QG(profile.title)) { model.applyProfile(profile) } } }
                    Text(QG("Apply blur strength and head sensitivity for your workspace; these presets also choose whether to keep only the current window clear.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                }
            }
            RuleCard(title: "Keyboard shortcuts", icon: "keyboard") {
                Text(QG("All configurable shortcuts start empty. Set the ones you need; Escape always clears protection.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                RuleSettingRow(title: "Rule shortcuts", detail: "Set a shortcut when editing a manual rule.") { Button(QG("Open auto & shortcuts")) { navigation.page = .rules } }
                Divider()
                RuleSettingRow(title: "Recenter", detail: "Reset the direction you are looking at.") {
                    RuleShortcutRecorder(model: model, binding: Binding(get: { coordinator.document.preferences.recenterShortcut }, set: { shortcut in
                        perform { var doc = coordinator.document; doc.preferences.recenterShortcut = shortcut; try coordinator.save(doc) }
                    }))
                }
                Text(QG("Escape clears all protection.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            }
            deviceSettings
            RuleCard(title: "About and updates", icon: "info.circle") {
                RuleSettingRow(title: "QuietGlass", detail: "Local screen, camera, and motion processing.") {
                    Button(QG("QuietGlass Help")) { if let url = Bundle.main.url(forResource: "QuietGlass Help", withExtension: "html") { NSWorkspace.shared.open(url) } }
                }
                Divider()
                RuleSettingRow(title: "Check automatically") {
                    Toggle(QG("Check automatically"), isOn: Binding(get: { model.updates.automatic }, set: { model.updates.automatic = $0 })).labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false)).controlSize(.small)
                }
                HStack {
                    Text(QG(model.updates.message)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                    Spacer()
                    Button(QG(model.updates.checking ? "Checking…" : "Check for updates")) { Task { await model.updates.check() } }.disabled(model.updates.checking)
                }
                if let page = model.updates.downloadPage { Button(QG("View download")) { NSWorkspace.shared.open(page) } }
            }
        }
    }
    private var permissions: some View {
        RuleCard(title: "Permissions and calibration", icon: "checkmark.shield") {
            RuleSettingRow(title: "Screen Recording", detail: model.rulePermissions.screenCheckPending ? "Checking access for this app session." : model.screenPermission ? "Ready to blur your screen." : model.rulePermissions.screenCheckUnavailable ? "Could not verify screen access" : "Allow access so QuietGlass can blur your screen.", warning: !model.screenPermission && !model.rulePermissions.screenCheckPending && !model.rulePermissions.screenCheckUnavailable) {
                if model.rulePermissions.screenCheckPending {
                    ProgressView().controlSize(.small)
                    Text(QG("Checking access…")).foregroundStyle(RulePalette.secondary)
                } else if model.screenPermission {
                    Label(QG("Granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.rulePermissions.screenCheckUnavailable {
                    Button(QG("Check again")) { model.verifyScreenPermission() }
                } else {
                    Button(QG(model.screenAccessAction)) { model.requestScreenPermission() }
                }
            }
            if model.screenCaptureNeedsRestart {
                Text(QG("Screen Recording is granted, but the capture session was rejected. Restart QuietGlass to apply access to this session.")).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if model.screenCaptureNeedsRestart || (model.screenAccessPreviouslyGranted && !model.screenPermission) { Button(QG("Restart QuietGlass")) { model.restartForScreenPermission() } }
            Divider()
            RuleSettingRow(title: "Camera", detail: "Used by nearby-person and camera head-tracking rules.", warning: !model.cameraPermissionGranted) {
                if !model.cameraPermissionGranted { Button(QG("Grant camera access")) { model.requestCameraPermission() } }
                CameraChoicePicker(cameras: model.nearby.cameras, selection: model.nearby.selectedCameraID,
                                   select: model.selectTrackingCamera, refresh: model.nearby.refreshCameras)
            }
            HStack(spacing: 8) {
                Button(QG("Camera coverage check")) { cameraCheck = true }
                Button(QG("Preview blur")) { model.previewShield() }
                Spacer(minLength: 0)
                Button(QG("Camera settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
            }
        }
    }
    private var deviceSettings: some View {
        RuleCard(title: "Device setup", icon: "airpodspro") {
            VStack(alignment: .leading, spacing: 10) {
                Text(QG("Head tracking")).font(.system(size: 13, weight: .medium))
                Text(QG("Face your display, then calibrate the source used by your rules.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                HStack(spacing: 8) {
                    ForEach(HeadTrackingSource.allCases) { source in
                        let configured = coordinator.document.rules.contains { rule in
                            if case .headTurn(let value) = rule.trigger { return value == source }; return false
                        }
                        if configured { Button(QG("Calibrate %@", QG(source.title))) { model.calibrateHeadSource(source) } }
                    }
                    Button(QG("Recenter")) { model.recenter() }.disabled(!model.canRecenter)
                    Spacer(minLength: 0)
                    Button(QG("Motion settings")) { model.openMotionSettings() }
                }
            }
            if model.cameraTracking.running && model.cameraTracking.policy.calibrating { ProgressView(value: model.cameraTracking.policy.progress) }
            if model.trackingSource == .airPods && model.perDisplayTracking {
                ForEach(model.connectedDisplays, id: \.id) { display in
                    RuleSettingRow(title: display.name) { Button(QG("Center display")) { model.calibrateDisplay(display.id) }.disabled(!model.canRecenter) }
                }
            }
            Divider()
            RuleSettingRow(title: "Recognize me", detail: model.nearby.owner.enrolled ? "Your saved face is available." : "Save your face to use recognition in nearby-person rules.") {
                Button(QG("Set up my face")) {
                    resumeAfterOwner = coordinator.plan.state == .running
                    if resumeAfterOwner { coordinator.pause() }
                    ownerSetup = true
                }.disabled(model.nearby.owner.busy)
            }
            if model.nearby.owner.enrolled { Button(QG("Delete saved face"), role: .destructive) { model.nearby.owner.deleteEnrollment() }.disabled(model.nearby.owner.busy) }
            Text(QG("Face templates stay in Keychain. Camera frames and recognized text are not saved.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            if let error = model.nearby.owner.error { Text(QG(error)).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func activatePreset(_ preset: ProtectionPreset) {
        do {
            let before = Set(coordinator.document.rules.map(\.id))
            let id = try coordinator.addPreset(preset)
            highlightedRuleID = id; presetFeedbackToken += 1
            if let rule = coordinator.document.rules.first(where: { $0.id == id }) {
                model.guideRulePermissions([rule])
                presetNotice = QG(before.contains(id) ? "Setup already exists: %@. It is enabled and highlighted below." : "Created %@. It is enabled and highlighted below.", QG(rule.name))
                if case .manual = rule.trigger { presetNotice = QG("%@ is ready. Choose Use now to activate this manual setup.", QG(rule.name)) }
            }
            message = nil
        } catch { message = "This change could not be saved. Check rule shortcuts and conditions." }
    }
    private func activate(_ rule: ProtectionRule) {
        if case .region(let ref, _, _) = rule.scope, ref.bundleID == "$selection" { model.privacy.chooseArea(recipeID: rule.id) }
        else if case .window(let ref) = rule.scope, ref.bundleID == "$selection" { model.privacy.chooseWindow(recipeID: rule.id) }
        else { model.privacy.ruleSources?.refresh(); coordinator.toggleManual(rule.id) }
    }
    private func perform(_ work: () throws -> Void) {
        do { try work(); message = nil } catch { message = "This change could not be saved. Check rule shortcuts and conditions." }
    }
}
