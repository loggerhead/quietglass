import AppKit
import SwiftUI
import ShieldCore
import LocalAuthentication
@testable import QuietGlass

@MainActor private final class TestExecutor: ProtectionPlanExecuting {
    func apply(_ plan: ProtectionPlan) {}
    func shutdown() {}
}

private final class EmptyOwnerStore: OwnerTemplateStoring {
    var containsTemplate: Bool { false }
    func read(context: LAContext) throws -> OwnerTemplate { throw OwnerSetupError.missingTemplate }
    func write(_ template: OwnerTemplate, context: LAContext) throws { throw OwnerSetupError.missingTemplate }
    func delete(context: LAContext) throws {}
}

@MainActor private final class TestFixture: ObservableObject {
    static let savedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let suite = "QuietGlass.UITests.\(UUID())"
    let model: AppModel
    let navigation = RuleNavigationState()
    let notch = NotchState()
    @Published var lastAction = "none"
    var coordinator: ProtectionCoordinator { model.protectionCoordinator! }

    init() throws {
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "automaticUpdateChecks")
        let owner = OwnerRecognition(store: EmptyOwnerStore(), authenticate: { _ in LAContext() }, cameraAccess: { false })
        let nearby = NearbyPeople(cameraAccess: { false }, usesWatchdog: false, owner: owner)
        model = AppModel(preferences: preferences, executor: TestExecutor(), nearby: nearby,
                         screenAccess: { true }, cameraPermission: { false }, runsRuleTimer: false, startsEventSources: false)
        model.requestRulePermission = { _ in }
        coordinator.prepareEscape = { true }
        coordinator.prepareRuleBindings = { _ in true }
        var rule = ProtectionPreset.nearby.rule()
        rule = ProtectionRule(id: Self.savedID, name: "Saved nearby", isEnabled: false,
                              trigger: rule.trigger, scope: rule.scope,
                              action: .warnThenBlur(delay: 13.5, sound: false), guards: rule.guards)
        try coordinator.saveRules([rule])
        model.presentRuleRegionSelection = { selected in
            selected(SelectedDisplayRegion(displayID: 202, normalizedRect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)))
        }
        model.onOpenPrivacySettings = { [weak self] in self?.lastAction = "settings" }
        model.onOpenRules = { [weak self] in self?.navigation.page = .rules }
        notch.expanded = true
        if ProcessInfo.processInfo.arguments.contains("--rules") { navigation.page = .rules }
    }

    func finish() { model.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
}

private struct FixtureView: View {
    @ObservedObject var fixture: TestFixture
    @ObservedObject var coordinator: ProtectionCoordinator
    let mode: String

    var body: some View {
        VStack(spacing: 0) {
            if mode == "notch" {
                NotchControlsView(model: fixture.model, close: {})
            } else if mode == "compact-notch" {
                NotchBarView(model: fixture.model, state: fixture.notch, hover: { _ in }, hint: { _ in },
                    action: { fixture.lastAction = String(describing: $0) }, drag: { _, _ in })
            } else {
                RuleWorkspaceView(model: fixture.model, coordinator: coordinator, navigation: fixture.navigation)
            }
            // Observable assertions live only in this test app, never in QuietGlass.
            HStack {
                Text(String(coordinator.document.rules.count)).accessibilityIdentifier("fixture.rule-count")
                Text(coordinator.document.rules.first { $0.id == TestFixture.savedID }?.name ?? "missing")
                    .accessibilityIdentifier("fixture.saved-name")
                Text(coordinator.document.rules.first { $0.id == TestFixture.savedID }?.id.uuidString ?? "missing")
                    .accessibilityIdentifier("fixture.saved-id")
                Text(coordinator.plan.hasProtection ? "blurred" : "clear").accessibilityIdentifier("fixture.coverage")
                Text(fixture.lastAction).accessibilityIdentifier("fixture.last-action")
                Text(coordinator.document.preferences.presetRuleIDs[ProtectionPreset.nearby.rawValue]?.uuidString ?? "none")
                    .accessibilityIdentifier("fixture.preset-id")
            }.font(.system(size: 8)).padding(8)
        }
    }
}

@MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var fixture: TestFixture?
    func applicationWillTerminate(_ notification: Notification) { fixture?.finish() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private enum NativeUITestHost {
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["QUIETGLASS_TEST_DESKTOP"].map({ ["isolated", "interactive"].contains($0) }) == true else {
            throw NSError(domain: "QuietGlass.UITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The UI test fixture requires explicit desktop-test opt-in."])
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let fixture = try TestFixture()
        let delegate = FixtureDelegate(); delegate.fixture = fixture; NSApp.delegate = delegate
        let args = ProcessInfo.processInfo.arguments
        let mode = args.contains("--notch") ? "notch" : args.contains("--compact-notch") ? "compact-notch" : "workspace"
        let size = mode == "workspace" ? CGSize(width: 1112, height: 880) : CGSize(width: 480, height: 800)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "QuietGlass UI Test Fixture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FixtureView(fixture: fixture, coordinator: fixture.coordinator, mode: mode))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        withExtendedLifetime((window, delegate, fixture)) { NSApp.run() }
    }
}
