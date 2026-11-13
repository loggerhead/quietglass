import AppKit
import SwiftUI
import ShieldCore

enum RuleEditorStage: Int, CaseIterable {
    case trigger, scope, action
    var title: String { switch self { case .trigger: return "When"; case .scope: return "Where"; case .action: return "Response" } }
}

@MainActor
struct RuleEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ProtectionCoordinator
    @State private var draft: RuleDraft
    @State private var stage: RuleEditorStage = .trigger
    @State private var saveError: String?
    @State private var conditionsExpanded = false
    @State private var regionShortcut: ShortcutBinding?
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, coordinator: ProtectionCoordinator, rule: ProtectionRule? = nil) {
        self.model = model; self.coordinator = coordinator
        var value = rule.map(RuleDraft.init) ?? RuleDraft(parameters: coordinator.document.preferences.defaultBlur)
        if rule == nil || { if case .warnThenBlur = rule?.action { return false }; if case .warnOnly = rule?.action { return false }; return true }() {
            value.delay = coordinator.document.preferences.defaultWarningDelay
            value.sound = coordinator.document.preferences.defaultWarningSound
        }
        if rule == nil { value.name = QG(value.name) }
        _draft = State(initialValue: value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(QG("Set up a response")).font(.system(size: 23, weight: .semibold))
                Text(QG(stageDescription)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            }
            HStack(spacing: 4) {
                ForEach(RuleEditorStage.allCases, id: \.rawValue) { step in
                    Button { stage = step } label: {
                        HStack(spacing: 8) {
                            Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(stage == step ? RulePalette.accent : Color.white.opacity(0.06), in: Circle())
                                .foregroundStyle(stage == step ? Color(white: 0.15) : RulePalette.secondary)
                            Text(QG(step.title)).font(.system(size: 13, weight: .medium))
                        }.foregroundStyle(stage == step ? RulePalette.text : RulePalette.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(stage == step ? RulePalette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }.padding(5).background(RulePalette.sidebar, in: RoundedRectangle(cornerRadius: 13))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch stage { case .trigger: triggerFields; case .scope: scopeFields; case .action: actionFields; conditions }
                    if let message = draft.errors.first {
                        Label(QG(message.message), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let saveError { Text(QG(saveError)).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(RulePalette.border)
            HStack {
                Button(QG("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(RuleButtonStyle(tone: .quiet))
                Spacer()
                if stage != .trigger { Button(QG("Back")) { stage = RuleEditorStage(rawValue: stage.rawValue - 1)! } }
                if stage != .action { Button(QG("Next")) { stage = RuleEditorStage(rawValue: stage.rawValue + 1)! }.buttonStyle(RuleButtonStyle(tone: .primary)) }
                else { Button(QG("Save rule"), action: save).disabled(!draft.canSave || model.recordingRuleShortcut).keyboardShortcut(.defaultAction).buttonStyle(RuleButtonStyle(tone: .primary)) }
            }
        }
        .padding(26).frame(width: 620, height: 650).background(RulePalette.background)
        .font(.system(size: 13)).foregroundStyle(RulePalette.text).tint(RulePalette.accent).preferredColorScheme(.dark)
        .buttonStyle(RuleButtonStyle())
        .disclosureGroupStyle(RuleDisclosureStyle())
        .toggleStyle(RuleToggleStyle())
        .accessibilityIdentifier("rule.editor")
        .onAppear(perform: updateRegionShortcut)
        .onChange(of: stage) { _, _ in updateRegionShortcut() }
        .onChange(of: draft.triggerKind) { _, _ in updateRegionShortcut() }
        .onChange(of: draft.scopeKind) { _, _ in updateRegionMarker() }
        .onChange(of: coordinator.document.preferences.regionSelectionShortcut) { _, _ in updateRegionShortcut() }
        .onChange(of: model.recordingRuleShortcut) { _, recording in if recording { model.endRuleRegionSelection() } else { updateRegionShortcut() } }
        .onDisappear { model.endRuleRegionSelection(); model.showRuleRegionMarker(nil) }
    }
    private var stageDescription: String {
        switch stage {
        case .trigger: return "Choose an automatic condition, or choose to use this setup by hand."
        case .scope: return "Choose the displays, window, or area affected by this setup."
        case .action: return "Choose a response and adjust what happens when this setup runs."
        }
    }
    private var triggerFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            RuleCard(title: "Basics", icon: "pencil") {
                TextField(QG("Rule name"), text: $draft.name).textFieldStyle(.roundedBorder)
                RuleSettingRow(title: "Allow this setup to run", detail: "The switch allows this setup to work; its condition decides when it responds.") {
                    Toggle(QG("Enabled"), isOn: $draft.enabled).labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false)).controlSize(.small)
                }
            }
            RuleCard(title: "When to protect", icon: "bolt") {
                RuleChoiceField(title: "Protect when", selection: Binding(get: { draft.triggerKind }, set: { draft.selectTrigger($0) }),
                    options: RuleTriggerKind.allCases.map { ($0, $0.title) })
                Divider()
                switch draft.triggerKind {
                case .manual:
                    RuleSettingRow(title: "Use a shortcut", detail: "Turn this rule on with a key combination.") {
                        Toggle(QG("Use a shortcut"), isOn: $draft.shortcutEnabled).labelsHidden().toggleStyle(RuleToggleStyle(showsLabel: false)).controlSize(.small)
                    }
                    if draft.shortcutEnabled { RuleShortcutRecorder(model: model, binding: $draft.shortcut) }
                case .headTurn:
                    RuleChoiceField(title: "Tracking source", selection: $draft.source, options: HeadTrackingSource.allCases.map { ($0, $0.title) })
                        .onChange(of: draft.source) { _, source in draft.cameraPermission = source == .camera; draft.motionPermission = source == .airPods }
                    Text(QG("Calibrate your head tracking in Settings before using this rule.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                case .extraFace:
                    RuleChoiceField(title: "Look for", selection: $draft.detection, options: NearbyDetection.allCases.map { ($0, $0 == .facingScreen ? "People facing the screen" : "Any other face") })
                case .sensitiveText:
                    Text(QG("Choose the information you want to hide.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    ForEach(SensitiveTextType.allCases, id: \.rawValue) { type in
                        Toggle(QG(type.title), isOn: Binding(get: { draft.types.contains(type) }, set: { if $0 { draft.types.insert(type) } else { draft.types.remove(type) } }))
                    }
                    Text(QG("Custom phrases, one per line")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    TextEditor(text: $draft.phraseText).frame(height: 90).padding(5)
                        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RulePalette.border))
                case .appEvent:
                    Button(QG("Choose app…")) { chooseApp(trigger: true) }
                    Text(applicationName(draft.triggerBundle)).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    RuleChoiceField(title: "Protect while", selection: $draft.appEvent, options: [(.activated, "The app is in front"), (.windowOpened, "The app has open windows")])
                    DisclosureGroup(QG("Advanced matching")) { TextField(QG("Application bundle ID"), text: $draft.triggerBundle).textFieldStyle(.roundedBorder).padding(.top, 8) }
                case .windowTitle:
                    Button(QG("Use active window"), action: useActiveWindow)
                    Text(QG("Remember this window and restore protection when it appears again.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    DisclosureGroup(QG("Advanced matching")) { TextField(QG("Application bundle ID"), text: $draft.triggerBundle).textFieldStyle(.roundedBorder).padding(.top, 8) }
                }
            }
        }
    }
    private var scopeFields: some View {
        RuleCard(title: "Where to protect", icon: "viewfinder") {
            RuleChoiceField(title: "Protect", selection: Binding(get: { draft.scopeKind }, set: { kind in
                draft.scopeKind = kind
                if kind == .selectedRegion { selectRegion() }
            }), options: draft.allowedScopes.map { ($0, $0.title) })
            if draft.allowedScopes.contains(.selectedRegion) {
                Divider()
                HStack {
                    Button { selectRegion() } label: { Label(QG("Select region"), systemImage: "crop") }
                        .buttonStyle(RuleButtonStyle(tone: .primary)).accessibilityIdentifier("rule.select-region")
                    Spacer()
                    RuleShortcutRecorder(model: model, binding: Binding(get: { coordinator.document.preferences.regionSelectionShortcut }, set: { value in
                        do { var document = coordinator.document; document.preferences.regionSelectionShortcut = value; try coordinator.save(document) }
                        catch { saveError = "This rule could not be saved. Check its shortcuts and conditions." }
                    }))
                }
                if let regionShortcut {
                    Text(QG("Move to any display and press %@ to select a region.", regionShortcut.label))
                        .font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                }
            }
            switch draft.scopeKind {
            case .allDisplays: Text(QG("This rule applies to every connected display.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            case .displays:
                ForEach(model.connectedDisplays, id: \.id) { display in
                    Toggle(display.name, isOn: Binding(get: { draft.displayIDs.contains(display.id) }, set: { if $0 { draft.displayIDs.insert(display.id) } else { draft.displayIDs.remove(display.id) } }))
                }
                if model.connectedDisplays.isEmpty { Text(QG("No displays available")).foregroundStyle(RulePalette.secondary) }
            case .selectedRegion:
                if draft.regionDisplayID == 0 {
                    Text(QG("Drag to select a region on any display. Escape cancels selection.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                } else {
                    let name = model.connectedDisplays.first { $0.id == draft.regionDisplayID }?.name ?? QG("Display %ld", Int(draft.regionDisplayID))
                    Label(QG("Selected region on %@", name), systemImage: "checkmark.circle").foregroundStyle(RulePalette.accent)
                    Text(QG("%ld%% × %ld%% of the display", Int(draft.rectangle.width * 100), Int(draft.rectangle.height * 100)))
                        .font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                }
            case .window, .region:
                Divider()
                if draft.triggerKind == .manual { Toggle(QG("Choose a window when activated"), isOn: $draft.chooseOnActivation) }
                if draft.chooseOnActivation {
                    Text(QG("Choose the window or area each time you use this rule.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                } else {
                    Text(applicationName(draft.targetBundle)).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
                    HStack { Button(QG("Use active window"), action: useActiveWindow); Button(QG("Choose app…")) { chooseApp(trigger: false) } }
                    DisclosureGroup(QG("Advanced matching")) {
                        TextField(QG("Target application bundle ID"), text: $draft.targetBundle).textFieldStyle(.roundedBorder).padding(.top, 8)
                    }.font(.system(size: 12))
                    if draft.windowID != nil {
                        Toggle(QG("Match this window only"), isOn: Binding(get: { draft.windowID != nil }, set: { if !$0 { draft.windowID = nil; draft.ownerPID = nil } }))
                        Text(QG("This selection lasts until the window closes.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                    }
                    if draft.scopeKind == .region {
                        DisclosureGroup(QG("Adjust the area")) {
                            VStack(spacing: 10) {
                                HStack { coordinate("X", \CGRect.origin.x); coordinate("Y", \CGRect.origin.y) }
                                HStack { coordinate("Width", \CGRect.size.width); coordinate("Height", \CGRect.size.height) }
                                Text(QG("Region coordinates range from 0 to 1 within the window.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                            }.padding(.top, 10)
                        }
                        Toggle(QG("Remember matching window titles"), isOn: $draft.rememberRegion)
                        if draft.rememberRegion { Text(QG("Use active window to remember its title.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary) }
                    }
                }
            case .detectedText: Text(QG("Only the matching text is blurred. The rest stays clear.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            case .focus: Text(QG("Your current window stays clear. Head-turn protection pauses while Focus is active.")).font(.system(size: 12)).foregroundStyle(RulePalette.secondary)
            }
        }
    }
    private func coordinate(_ title: String, _ path: WritableKeyPath<CGRect, CGFloat>) -> some View {
        TextField(QG(title), value: Binding(get: { Double(draft.rectangle[keyPath: path]) }, set: { draft.rectangle[keyPath: path] = CGFloat($0) }), format: .number).textFieldStyle(.roundedBorder)
    }
    private func applicationName(_ identifier: String) -> String {
        guard !identifier.isEmpty else { return QG("No application selected") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return QG("Selected application") }
        return (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    private func updateRegionShortcut() {
        model.endRuleRegionSelection()
        updateRegionMarker()
        regionShortcut = stage == .scope && draft.allowedScopes.contains(.selectedRegion)
            ? model.beginRuleRegionSelection(action: selectRegion) : nil
    }
    private func updateRegionMarker() {
        model.showRuleRegionMarker(draft.scopeKind == .selectedRegion && draft.regionDisplayID != 0
            ? SelectedDisplayRegion(displayID: draft.regionDisplayID, normalizedRect: draft.rectangle) : nil)
    }
    private func selectRegion() {
        guard draft.allowedScopes.contains(.selectedRegion) else { return }
        model.chooseRuleRegion { selection in draft.setDisplayRegion(selection) }
    }
    private var actionFields: some View {
        RuleCard(title: "How to protect", icon: "lock.shield") {
            RuleChoiceField(title: "Respond with", selection: $draft.actionKind, options: draft.allowedActions.map { ($0, $0.title) })
            Divider()
            switch draft.actionKind {
            case .blur:
                RuleSettingRow(title: "Blur strength") {
                    HStack(spacing: 10) { Slider(value: $draft.blur.radius, in: 10...70, step: 1).frame(width: 190); Text(draft.blur.radius, format: .number.precision(.fractionLength(0))).monospacedDigit().frame(width: 25) }
                }
                if draft.triggerKind == .headTurn {
                    RuleSettingRow(title: "Start angle") { Slider(value: $draft.blur.comfort, in: 2...30, step: 1).frame(width: 220) }
                    RuleSettingRow(title: "Transition angle") { Slider(value: $draft.blur.transition, in: 5...30, step: 1).frame(width: 220) }
                }
                if draft.triggerKind == .manual && !draft.chooseOnActivation {
                    Toggle(QG("Hold to peek"), isOn: $draft.peekEnabled)
                    if draft.peekEnabled { RuleShortcutRecorder(model: model, binding: $draft.peekShortcut) }
                }
            case .warnThenBlur, .warnOnly:
                RuleSettingRow(title: draft.actionKind == .warnThenBlur ? "Blur after" : "Warning countdown") {
                    HStack(spacing: 8) { TextField(QG("Seconds"), value: $draft.delay, format: .number).textFieldStyle(.roundedBorder).frame(width: 80); Text(QG("seconds")).foregroundStyle(RulePalette.secondary) }
                }
                Text(QG(draft.actionKind == .warnThenBlur ? "The warning appears immediately. Content is blurred when the countdown ends." : "The countdown ending does not turn on blur. Use Blur now if you want to hide content."))
                    .font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                Toggle(QG("Warning sound"), isOn: $draft.sound)
                if draft.actionKind == .warnOnly { Text(QG("Show a warning without automatically blurring. You can still choose Blur now.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary) }
            case .pause:
                Toggle(QG("Pause until the condition ends"), isOn: $draft.indefinitePause)
                if !draft.indefinitePause { TextField(QG("Pause duration in seconds"), value: $draft.pauseDuration, format: .number).textFieldStyle(.roundedBorder) }
                Toggle(QG("Pause head-turn rules only"), isOn: $draft.pauseHeadsOnly)
            }
        }
    }
    private var conditions: some View {
        DisclosureGroup(QG("Extra requirements"), isExpanded: $conditionsExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text(QG("Every selected requirement must be met before this setup can run. Leave them off if you do not need a restriction.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                if draft.triggerKind == .extraFace {
                    Toggle(QG("Recognize me"), isOn: $draft.ownerVerification)
                    Text(QG("If your identity cannot be confirmed, protection stays conservative. Save your face in Settings first.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                }
                if draft.triggerKind == .headTurn { Toggle(QG("Only after head tracking is calibrated"), isOn: $draft.calibration) }
                Divider()
                Toggle(QG("Only while a chosen app is in front"), isOn: $draft.appConditionEnabled)
                Text(QG("Example: use this setup only while working in a particular app.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                if draft.appConditionEnabled {
                    HStack { Text(applicationName(draft.appCondition)); Spacer(); Button(QG("Choose app…")) { chooseConditionApp() } }
                    DisclosureGroup(QG("Application ID")) { TextField(QG("Application bundle ID"), text: $draft.appCondition).textFieldStyle(.roundedBorder) }
                }
                Divider()
                Toggle(QG("Only during chosen hours"), isOn: $draft.timeEnabled)
                Text(QG("Uses this Mac’s local time, including time ranges that cross midnight.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                if draft.timeEnabled {
                    Text(QG("Allowed time: %02ld:%02ld – %02ld:%02ld", draft.startHour, draft.startMinute, draft.endHour, draft.endMinute)).monospacedDigit()
                    HStack {
                        Stepper(QG("Start hour: %ld", draft.startHour), value: $draft.startHour, in: 0...23)
                        Stepper(QG("Start minute: %ld", draft.startMinute), value: $draft.startMinute, in: 0...59)
                    }
                    HStack {
                        Stepper(QG("End hour: %ld", draft.endHour), value: $draft.endHour, in: 0...23)
                        Stepper(QG("End minute: %ld", draft.endMinute), value: $draft.endMinute, in: 0...59)
                    }
                }
                Divider()
                Stepper(QG("Priority: %ld", draft.priority), value: $draft.priority, in: -1000...1000)
                Text(QG("When similar setups overlap, higher values choose which settings take precedence. Usually you can leave this at 0.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                DisclosureGroup(QG("Advanced access and pause checks")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(QG("These checks require existing access; they do not turn on additional camera or motion sampling. System permissions are still required for screen blur and detection.")).font(.system(size: 11)).foregroundStyle(RulePalette.secondary)
                        Toggle(QG("Require Screen Recording access"), isOn: $draft.screenPermission)
                        Toggle(QG("Require camera access"), isOn: $draft.cameraPermission)
                        Toggle(QG("Require Motion & Fitness access"), isOn: $draft.motionPermission)
                        Toggle(QG("Require protection to be unpaused"), isOn: $draft.notPaused)
                    }.padding(.top, 8)
                }
            }.padding(.top, 14)
        }.font(.system(size: 12)).padding(16).background(RulePalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RulePalette.border))
    }
    private func chooseConditionApp() {
        let chooser = NSOpenPanel(); chooser.allowedContentTypes = [.applicationBundle]; chooser.canChooseDirectories = false
        chooser.begin { response in
            guard response == .OK, let url = chooser.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            draft.appCondition = bundle
        }
    }
    private func save() {
        guard draft.canSave else { return }
        var rules = coordinator.document.rules
        if let index = rules.firstIndex(where: { $0.id == draft.id }) { rules[index] = draft.rule } else { rules.append(draft.rule) }
        do { try coordinator.saveRules(rules); if draft.enabled { model.guideRulePermissions([draft.rule]) }; dismiss() }
        catch { saveError = "This rule could not be saved. Check its shortcuts and conditions." }
    }
    private func useActiveWindow() {
        guard let source = model.privacy.ruleSources, let pid = source.frontPID,
              let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier else { return }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let item = PrivacyController.frontWindowItem(in: raw, for: pid), let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return }
        let title = item[kCGWindowName as String] as? String
        let digest = draft.triggerKind == .windowTitle || draft.rememberRegion ? title.flatMap { $0.isEmpty ? nil : RuleEventSources.titleDigest($0) } : nil
        draft.setWindow(ProtectedWindowRef(bundleID: bundle, windowID: id, ownerPID: pid, titleDigest: digest))
        if draft.triggerKind == .windowTitle { draft.windowID = nil; draft.ownerPID = nil; draft.rememberRegion = true }
    }
    private func chooseApp(trigger: Bool) {
        let chooser = NSOpenPanel(); chooser.allowedContentTypes = [.applicationBundle]; chooser.canChooseDirectories = false
        chooser.begin { response in
            guard response == .OK, let url = chooser.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            if trigger { draft.triggerBundle = bundle; if draft.targetBundle.isEmpty { draft.targetBundle = bundle } }
            else { draft.targetBundle = bundle; draft.windowID = nil; draft.ownerPID = nil; draft.titleDigest = "" }
        }
    }
}

extension SensitiveTextType {
    var title: String { switch self { case .credentials: return "Passwords and keys"; case .emailAddresses: return "Email addresses"; case .paymentCards: return "Payment cards" } }
}
