import Foundation
import ShieldCore

/// Connects reusable camera/presence policies to the same rule coordinator used
/// by every protection source. No nearby preference or warning evaluator exists here.
@MainActor
final class NearbyRuleAdapter {
    let coordinator: ProtectionCoordinator
    private let nearby: NearbyPeople
    private let cameraPermission: () -> Bool
    var onError: ((Error) -> Void)?

    init(nearby: NearbyPeople, coordinator: ProtectionCoordinator, cameraPermission: @escaping () -> Bool) {
        self.nearby = nearby; self.coordinator = coordinator; self.cameraPermission = cameraPermission
        nearby.onRuleCommand = { [weak self] in self?.handle($0) }
        nearby.onRuleDetection = { [weak self] mode, active, verified, monitoring in
            self?.receive([(mode, active, verified, monitoring)])
        }
        nearby.onRuleDetections = { [weak self] in self?.receive($0) }
        nearby.owner.onTemplateAvailabilityChange = { [weak self] available in
            guard let self else { return }
            let required = self.coordinator.document.rules.contains { rule in
                if case .extraFace = rule.trigger { return rule.guards.contains(.ownerVerification) }; return false
            }
            self.nearby.owner.configureRuleVerification(required)
            if required && !available { self.nearby.invalidateRuleOwnerVerification() }
        }
    }
    private func receive(_ values: [(NearbyDetection, Bool, Bool, Bool)]) {
        coordinator.send([.permission(.camera, granted: cameraPermission())] + values.flatMap { mode, active, verified, monitoring in
            [.nearbyMonitoring(mode, monitoring), .nearby(mode, active: active, ownerVerified: verified)]
        })
    }
    func configure(_ document: ProtectionDocument, startIfNeeded: Bool = true) {
        let values = (try? PropertyListSerialization.propertyList(from: document.preferences.appearance, format: nil)) as? [String: Any] ?? [:]
        nearby.configureRules(document.rules, cameraID: values["nearbyCameraID"] as? String ?? "", startIfNeeded: startIfNeeded, defaults: document.preferences)
    }
    func present(_ plan: ProtectionPlan) {
        let ids = Set(coordinator.document.rules.filter { if case .extraFace = $0.trigger { return true }; return false }.map(\.id))
        nearby.presentRulePlan(plan, ruleIDs: ids)
    }
    private func handle(_ command: NearbyRuleCommand) {
        switch command {
        case .blurNow: for warning in coordinator.plan.warnings { coordinator.blurNow(warning.id) }; return
        case .pause: coordinator.pause(seconds: 300); return
        case .resume: coordinator.resume(); return
        case .tick: coordinator.send(.tick); present(coordinator.plan); return
        default: break
        }
        var document = coordinator.document
        do {
            if case .camera(let id) = command {
                var values = (try? PropertyListSerialization.propertyList(from: document.preferences.appearance, format: nil)) as? [String: Any] ?? [:]
                values["nearbyCameraID"] = id
                document.preferences.appearance = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            } else {
                guard let index = document.rules.firstIndex(where: { if case .extraFace = $0.trigger { return true }; return false }) else { return }
                let action = document.rules[index].action
                switch command {
                case .enabled(let value):
                    for candidate in document.rules.indices { if case .extraFace = document.rules[candidate].trigger { document.rules[candidate].isEnabled = value } }
                case .detection(let value): document.rules[index].trigger = .extraFace(detection: value)
                case .response(let value): document.rules[index].action = value == .blur ? .blur(document.preferences.defaultBlur, peek: nil) : .warnThenBlur(delay: nearby.warningDelay, sound: nearby.warningSoundEnabled)
                case .delay(let value):
                    let delay = NearbyWarningPolicy.normalizedDelay(value)
                    document.preferences.defaultWarningDelay = delay
                    switch action {
                    case .warnOnly(_, let sound): document.rules[index].action = .warnOnly(delay: delay, sound: sound)
                    case .warnThenBlur(_, let sound): document.rules[index].action = .warnThenBlur(delay: delay, sound: sound)
                    default: break
                    }
                case .sound(let sound):
                    document.preferences.defaultWarningSound = sound
                    switch action {
                    case .warnOnly(let delay, _): document.rules[index].action = .warnOnly(delay: delay, sound: sound)
                    case .warnThenBlur(let delay, _): document.rules[index].action = .warnThenBlur(delay: delay, sound: sound)
                    default: break
                    }
                default: break
                }
            }
            try coordinator.save(document)
        } catch { onError?(error) }
    }
}
