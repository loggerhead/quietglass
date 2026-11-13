import Foundation

public struct ProtectionPreferences: Codable, Equatable {
    public var defaultBlur: BlurParameters
    public var defaultWarningDelay: TimeInterval
    public var defaultWarningSound: Bool
    public var recenterShortcut: ShortcutBinding?
    public var regionSelectionShortcut: ShortcutBinding?
    public var shortcutDefaultsVersion: Int
    public var presetRuleIDs: [String: UUID]
    /// The original local appearance/system preferences, encoded as a property list.
    /// These values configure adapters and presentation; they never activate protection.
    public var appearance: Data
    public init(defaultBlur: BlurParameters = BlurParameters(),
                recenterShortcut: ShortcutBinding? = nil,
                appearance: Data = Data(), defaultWarningDelay: TimeInterval = 120, defaultWarningSound: Bool = true) {
        self.defaultBlur = defaultBlur; self.recenterShortcut = recenterShortcut; self.appearance = appearance
        self.defaultWarningDelay = defaultWarningDelay; self.defaultWarningSound = defaultWarningSound
        regionSelectionShortcut = nil; shortcutDefaultsVersion = 1; presetRuleIDs = [:]
    }
    private enum CodingKeys: String, CodingKey { case defaultBlur, recenterShortcut, regionSelectionShortcut, shortcutDefaultsVersion, presetRuleIDs, appearance, defaultWarningDelay, defaultWarningSound }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultBlur = try values.decode(BlurParameters.self, forKey: .defaultBlur)
        recenterShortcut = try values.decodeIfPresent(ShortcutBinding.self, forKey: .recenterShortcut)
        regionSelectionShortcut = try values.decodeIfPresent(ShortcutBinding.self, forKey: .regionSelectionShortcut)
        shortcutDefaultsVersion = try values.decodeIfPresent(Int.self, forKey: .shortcutDefaultsVersion) ?? 0
        presetRuleIDs = try values.decodeIfPresent([String: UUID].self, forKey: .presetRuleIDs) ?? [:]
        appearance = try values.decode(Data.self, forKey: .appearance)
        defaultWarningDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .defaultWarningDelay) ?? 120
        defaultWarningSound = try values.decodeIfPresent(Bool.self, forKey: .defaultWarningSound) ?? true
    }

}

public struct ProtectionDocument: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var rules: [ProtectionRule]
    public var preferences: ProtectionPreferences
    public init(rules: [ProtectionRule], preferences: ProtectionPreferences = ProtectionPreferences()) {
        self.rules = rules; self.preferences = preferences
    }
}

public enum ProtectionStoreError: Error, Equatable {
    case unsupportedSchema(Int), invalidDocument, corruptLegacy(String), commitFailed
}

/// Write-through storage, injectable so migration and rollback are tested without real preferences.
public protocol ProtectionPreferencesStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}
extension UserDefaults: ProtectionPreferencesStorage {}

public final class ProtectionStore {
    public static let documentKey = "protectionRules.v1"
    public static let backupKey = "protectionRules.legacyBackup.v1"
    public static let legacyKeys = [
        "privacyScanEnabled", "privacyScanOptions", "privacyCustomPhrases", "privacyAppRules", "privacySavedAreas",
        "nearbyEnabled", "nearbyResponse", "nearbyDetection", "nearbyWarningDelay", "nearbyWarningSound", "nearbyPauseUntil",
        "ownerRecognitionEnabled", "headTrackingSource", "comfort", "transition", "blur",
        "shortcutKey", "shortcutModifiers", "shortcutLabel", "privacyShortcutKey", "privacyShortcutModifiers", "privacyShortcutLabel",
        "peekShortcutKey", "peekShortcutModifiers", "peekShortcutLabel", "areaShortcutKey", "areaShortcutModifiers", "areaShortcutLabel",
        "includeBlurInCaptures", "nearbyCameraID", "headSetupCompleted.v1", "screenAccessPreviouslyGranted",
        "notchUsesCustomPosition", "notchAnchorX", "notchAnchorY", "notchDockEdge", "automaticUpdateChecks", "lastUpdateCheck"
    ]
    private let storage: ProtectionPreferencesStorage
    public init(storage: ProtectionPreferencesStorage = UserDefaults.standard) { self.storage = storage }

    public func loadOrMigrate() throws -> ProtectionDocument {
        if let existing = storage.object(forKey: Self.documentKey) {
            guard let data = existing as? Data else { throw ProtectionStoreError.invalidDocument }
            var document = try decode(data)
            if document.preferences.shortcutDefaultsVersion < 1 {
                document.preferences.recenterShortcut = nil; document.preferences.regionSelectionShortcut = nil
                document.preferences.shortcutDefaultsVersion = 1
                for index in document.rules.indices {
                    if case .manual = document.rules[index].trigger { document.rules[index].trigger = .manual(shortcut: nil) }
                    if case .blur(let parameters, .some) = document.rules[index].action { document.rules[index].action = .blur(parameters, peek: nil) }
                }
                try save(document)
            }
            return document
        }
        let snapshot = Dictionary(uniqueKeysWithValues: Self.legacyKeys.compactMap { key in storage.object(forKey: key).map { (key, $0) } })
        let backup = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        // Keep the first pre-migration snapshot, including malformed legacy values.
        if storage.object(forKey: Self.backupKey) == nil {
            storage.set(backup, forKey: Self.backupKey)
            guard storage.object(forKey: Self.backupKey) as? Data == backup else { throw ProtectionStoreError.commitFailed }
        }
        let document = try LegacyProtectionMigration.migrate(snapshot)
        try save(document)
        return document
    }
    public func save(_ document: ProtectionDocument) throws {
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        _ = try decode(data)
        let previous = storage.object(forKey: Self.documentKey)
        storage.set(data, forKey: Self.documentKey)
        guard storage.object(forKey: Self.documentKey) as? Data == data else {
            if let previous { storage.set(previous, forKey: Self.documentKey) } else { storage.removeObject(forKey: Self.documentKey) }
            throw ProtectionStoreError.commitFailed
        }
    }
    public func decode(_ data: Data) throws -> ProtectionDocument {
        let document = try JSONDecoder().decode(ProtectionDocument.self, from: data)
        try validate(document)
        return document
    }
    private func validate(_ document: ProtectionDocument) throws {
        guard document.schemaVersion == 1 else { throw ProtectionStoreError.unsupportedSchema(document.schemaVersion) }
        _ = try ProtectionEngine(rules: document.rules)
        let probe = ProtectionRule(name: "Validation", trigger: .manual(shortcut: document.preferences.recenterShortcut), scope: .allDisplays,
                                   action: .blur(document.preferences.defaultBlur, peek: nil))
        let selectionProbe = ProtectionRule(name: "Selection", trigger: .manual(shortcut: document.preferences.regionSelectionShortcut), scope: .allDisplays)
        guard ProtectionRuleValidator.validate(probe).isEmpty, document.preferences.defaultWarningDelay.isFinite,
              ProtectionRuleValidator.validate(selectionProbe).isEmpty,
              (0...NearbyWarningPolicy.maximumDelay).contains(document.preferences.defaultWarningDelay) else { throw ProtectionStoreError.invalidDocument }
    }
}

public enum ProtectionPreset: String, CaseIterable {
    case nearby, headTurn, sensitiveText, focus
    public func rule(parameters: BlurParameters = BlurParameters(), source: HeadTrackingSource = .airPods, warningDelay: TimeInterval = 120, warningSound: Bool = true) -> ProtectionRule {
        switch self {
        case .nearby:
            return ProtectionRule(name: "Someone nearby", trigger: .extraFace(detection: .facingScreen), scope: .allDisplays,
                                  action: .warnThenBlur(delay: warningDelay, sound: warningSound), guards: [.permission(.camera), .notPaused])
        case .headTurn:
            return ProtectionRule(name: "Look away", trigger: .headTurn(source: source), scope: .allDisplays,
                                  action: .blur(parameters, peek: nil), guards: [.permission(source == .camera ? .camera : .motion), .permission(.screen), .calibrationRequired, .notPaused])
        case .sensitiveText:
            return ProtectionRule(name: "Sensitive information", trigger: .sensitiveText(types: [.credentials], phrases: []),
                                  scope: .detectedText, action: .blur(parameters, peek: nil), guards: [.permission(.screen), .notPaused])
        case .focus:
            return ProtectionRule(name: "Focus", trigger: .manual(shortcut: nil), scope: .allDisplaysExceptActiveWindow,
                                  action: .blur(parameters, peek: nil), guards: [.permission(.screen), .notPaused])
        }
    }
}

public enum LegacyProtectionMigration {
    public static func migrate(_ values: [String: Any]) throws -> ProtectionDocument {
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let value = values[key] else { return fallback }
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw ProtectionStoreError.corruptLegacy(key) }
            return min(range.upperBound, max(range.lowerBound, number.doubleValue))
        }
        func bool(_ key: String, fallback: Bool = false) throws -> Bool {
            guard let value = values[key] else { return fallback }
            guard let flag = value as? Bool else { throw ProtectionStoreError.corruptLegacy(key) }; return flag
        }
        func string(_ key: String, fallback: String) throws -> String {
            guard let value = values[key] else { return fallback }
            guard let text = value as? String else { throw ProtectionStoreError.corruptLegacy(key) }; return text
        }
        // Existing shortcuts are intentionally cleared once for the new manual-assignment policy.
        func legacyArray<T: Decodable>(_ key: String, type: T.Type) throws -> [T] {
            guard let raw = values[key] else { return [] }
            guard let data = raw as? Data, let result = try? JSONDecoder().decode([T].self, from: data) else { throw ProtectionStoreError.corruptLegacy(key) }
            return result
        }
        let parameters = try BlurParameters(radius: number("blur", fallback: 28, range: 10...70),
                                            comfort: number("comfort", fallback: 15, range: 2...30),
                                            transition: number("transition", fallback: 18, range: 5...30))
        let sourceString = try string("headTrackingSource", fallback: "airPods")
        guard let source = HeadTrackingSource(rawValue: sourceString) else { throw ProtectionStoreError.corruptLegacy("headTrackingSource") }
        var rules: [ProtectionRule] = [
            ProtectionRule(name: "Blur screen now", trigger: .manual(shortcut: nil), scope: .allDisplays,
                           action: .blur(parameters, peek: nil), guards: [.permission(.screen)]),
            ProtectionRule(name: "Select an area", trigger: .manual(shortcut: nil),
                           scope: .region(ProtectedWindowRef(bundleID: "$selection"), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), persistence: .session),
                           action: .blur(parameters, peek: nil), guards: [.permission(.screen)]),
            ProtectionRule(name: "Protect a window", trigger: .manual(shortcut: nil), scope: .window(ProtectedWindowRef(bundleID: "$selection")),
                           action: .blur(parameters, peek: nil), guards: [.permission(.screen)]),
            ProtectionPreset.focus.rule(parameters: parameters),
            ProtectionPreset.headTurn.rule(parameters: parameters, source: source)
        ]
        // Tracking was never automatically started by the old app. Sensor startup remains opt-in.
        rules[4].isEnabled = false
        var scan = ProtectionPreset.sensitiveText.rule(parameters: parameters)
        scan.isEnabled = try bool("privacyScanEnabled")
        let rawOptions = try number("privacyScanOptions", fallback: 1, range: 0...Double(Int32.max))
        guard Int(rawOptions) & ~7 == 0 else { throw ProtectionStoreError.corruptLegacy("privacyScanOptions") }
        let options = SensitiveTextOptions(rawValue: Int(rawOptions))
        let rawPhrases: [String]
        if let value = values["privacyCustomPhrases"] {
            guard let phrases = value as? [String] else { throw ProtectionStoreError.corruptLegacy("privacyCustomPhrases") }; rawPhrases = phrases
        } else { rawPhrases = [] }
        let types = Set(SensitiveTextType.allCases.filter { options.contains($0.option) })
        let phrases = SensitiveText.cleanPhrases(rawPhrases)
        // An empty legacy detector has no behavior; keep a disabled editable template.
        scan.trigger = .sensitiveText(types: types.isEmpty && phrases.isEmpty ? [.credentials] : types, phrases: phrases)
        if types.isEmpty && phrases.isEmpty { scan.isEnabled = false }
        rules.append(scan)
        let detectionString = try string("nearbyDetection", fallback: "facingScreen")
        guard let detection = NearbyDetection(rawValue: detectionString) else { throw ProtectionStoreError.corruptLegacy("nearbyDetection") }
        let response = try string("nearbyResponse", fallback: "blur")
        guard ["blur", "warning"].contains(response) else { throw ProtectionStoreError.corruptLegacy("nearbyResponse") }
        var nearby = ProtectionPreset.nearby.rule(parameters: parameters)
        nearby.isEnabled = try bool("nearbyEnabled")
        nearby.trigger = .extraFace(detection: detection)
        let sound = try bool("nearbyWarningSound", fallback: true)
        let delay = NearbyWarningPolicy.normalizedDelay(try number("nearbyWarningDelay", fallback: 120, range: 0...NearbyWarningPolicy.maximumDelay))
        nearby.action = response == "warning" ? .warnThenBlur(delay: delay, sound: sound) : .blur(parameters, peek: nil)
        if try bool("ownerRecognitionEnabled") { nearby.guards.append(.ownerVerification) }
        rules.append(nearby)
        for app in try legacyArray("privacyAppRules", type: AppPrivacyRule.self) {
            guard !app.bundleID.isEmpty else { throw ProtectionStoreError.corruptLegacy("privacyAppRules") }
            if app.protectWindows {
                rules.append(ProtectionRule(name: app.name, trigger: .appEvent(bundleID: app.bundleID, event: .windowOpened),
                                            scope: .window(ProtectedWindowRef(bundleID: app.bundleID)), action: .blur(parameters, peek: nil), guards: [.permission(.screen), .notPaused]))
            }
            if app.mode == .pause {
                // Preserve the legacy distinction between pausing head tracking and all protection.
                let pause = ProtectionRule(name: app.name, trigger: .appEvent(bundleID: app.bundleID, event: .activated),
                                           scope: .allDisplaysExceptActiveWindow, action: .pauseOtherProtection(duration: nil, target: .headTurn), guards: [.notPaused])
                rules.append(pause)
            } else if app.mode == .stronger {
                let strong = app.mode.settings(comfort: parameters.comfort, transition: parameters.transition, blur: parameters.radius)
                var head = ProtectionPreset.headTurn.rule(parameters: BlurParameters(radius: strong.blur, comfort: strong.comfort, transition: strong.transition), source: source)
                head.name = app.name; head.priority = 100; head.isEnabled = false
                head.guards.append(.appCondition(bundleID: app.bundleID)); rules.append(head)
            }
        }
        for area in try legacyArray("privacySavedAreas", type: SavedWindowArea.self) {
            guard area.isValid else { throw ProtectionStoreError.corruptLegacy("privacySavedAreas") }
            let ref = ProtectedWindowRef(bundleID: area.bundleID, titleDigest: area.titleDigest)
            rules.append(ProtectionRule(id: area.id, name: area.appName, trigger: .windowTitle(bundleID: area.bundleID, titleDigest: area.titleDigest),
                                        scope: .region(ref, normalizedRect: area.rectangle, persistence: .rememberWindowTitle), action: .blur(parameters, peek: nil), guards: [.permission(.screen), .notPaused]))
        }
        let appearanceKeys = ["includeBlurInCaptures", "nearbyCameraID", "headSetupCompleted.v1", "screenAccessPreviouslyGranted",
                              "notchUsesCustomPosition", "notchAnchorX", "notchAnchorY", "notchDockEdge", "automaticUpdateChecks", "lastUpdateCheck", "nearbyPauseUntil"]
        let appearance = try PropertyListSerialization.data(fromPropertyList: values.filter { appearanceKeys.contains($0.key) }, format: .binary, options: 0)
        let preferences = try ProtectionPreferences(defaultBlur: parameters, appearance: appearance, defaultWarningDelay: delay, defaultWarningSound: sound)
        let document = ProtectionDocument(rules: rules, preferences: preferences)
        _ = try ProtectionEngine(rules: rules)
        return document
    }
}
