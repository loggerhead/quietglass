import XCTest
@testable import ShieldCore

private final class MemoryProtectionPreferences: ProtectionPreferencesStorage {
    var values: [String: Any]
    var rejectDocumentWrites = false
    init(_ values: [String: Any] = [:]) { self.values = values }
    func testExistingV1DocumentWithoutWarningDefaultsLoadsCompatibly() throws {
        let document = ProtectionDocument(rules: [ProtectionPreset.nearby.rule()])
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var preferences = try XCTUnwrap(values["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "defaultWarningDelay"); preferences.removeValue(forKey: "defaultWarningSound")
        values["preferences"] = preferences
        let decoded = try JSONDecoder().decode(ProtectionDocument.self, from: JSONSerialization.data(withJSONObject: values))
        XCTAssertEqual(decoded.rules, document.rules)
        XCTAssertEqual(decoded.preferences.defaultWarningDelay, 120)
        XCTAssertTrue(decoded.preferences.defaultWarningSound)
    }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        if key == ProtectionStore.documentKey && rejectDocumentWrites { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class ProtectionStoreTests: XCTestCase {
    func testEmptyPreferencesMigrateToValidInactiveManualAndSensorTemplates() throws {
        let storage = MemoryProtectionPreferences()
        let document = try ProtectionStore(storage: storage).loadOrMigrate()
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.rules.count, 7)
        XCTAssertTrue(document.rules.allSatisfy { ProtectionRuleValidator.validate($0).isEmpty })
        XCTAssertFalse(document.rules.contains { rule in
            if case .headTurn = rule.trigger { return rule.isEnabled }
            if case .extraFace = rule.trigger { return rule.isEnabled }
            if case .sensitiveText = rule.trigger { return rule.isEnabled }
            return false
        })
        XCTAssertEqual(document.preferences.defaultBlur, BlurParameters())
        XCTAssertNotNil(storage.values[ProtectionStore.backupKey])
    }

    func testCompleteConfigurationPreservesEveryBehaviorAndModifier() throws {
        let area = SavedWindowArea(bundleID: "example.editor", appName: "Editor", windowTitle: "Private title", rectangle: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let apps = [AppPrivacyRule(bundleID: "example.editor", name: "Editor", mode: .stronger, protectWindows: true),
                    AppPrivacyRule(bundleID: "example.reader", name: "Reader", mode: .pause)]
        let legacy: [String: Any] = [
            "privacyScanEnabled": true, "privacyScanOptions": 7, "privacyCustomPhrases": ["Private phrase"],
            "privacyAppRules": try JSONEncoder().encode(apps), "privacySavedAreas": try JSONEncoder().encode([area]),
            "nearbyEnabled": true, "nearbyResponse": "warning", "nearbyDetection": "anyFace",
            "nearbyWarningDelay": 180.0, "nearbyWarningSound": false, "ownerRecognitionEnabled": true,
            "headTrackingSource": "camera", "comfort": 20.0, "transition": 25.0, "blur": 60.0,
            "privacyShortcutKey": 11, "privacyShortcutModifiers": 256, "privacyShortcutLabel": "⌘B",
            "areaShortcutKey": 12, "areaShortcutModifiers": 512, "areaShortcutLabel": "⇧Q",
            "peekShortcutKey": 49, "peekShortcutModifiers": 2048, "peekShortcutLabel": "⌥Space",
            "shortcutKey": 13, "shortcutModifiers": 4096, "shortcutLabel": "⌃W",
            "includeBlurInCaptures": true, "nearbyCameraID": "camera-id", "notchAnchorX": 100.0,
            "nearbyPauseUntil": Date(timeIntervalSince1970: 1000)
        ]
        let storage = MemoryProtectionPreferences(legacy)
        let document = try ProtectionStore(storage: storage).loadOrMigrate()
        XCTAssertEqual(document.rules.count, 11)
        let scan = try XCTUnwrap(document.rules.first { if case .sensitiveText = $0.trigger { return true }; return false })
        XCTAssertEqual(scan.trigger, .sensitiveText(types: Set(SensitiveTextType.allCases), phrases: ["Private phrase"]))
        XCTAssertTrue(scan.isEnabled)
        let nearby = try XCTUnwrap(document.rules.first { if case .extraFace = $0.trigger { return true }; return false })
        XCTAssertEqual(nearby.trigger, .extraFace(detection: .anyFace))
        XCTAssertEqual(nearby.action, .warnThenBlur(delay: 180, sound: false)); XCTAssertTrue(nearby.guards.contains(.ownerVerification))
        XCTAssertTrue(nearby.isEnabled)
        let saved = try XCTUnwrap(document.rules.first { $0.id == area.id })
        XCTAssertEqual(saved.scope, .region(ProtectedWindowRef(bundleID: area.bundleID, titleDigest: area.titleDigest), normalizedRect: area.rectangle, persistence: .rememberWindowTitle))
        let pause = try XCTUnwrap(document.rules.first { if case .pauseOtherProtection = $0.action { return true }; return false })
        XCTAssertTrue(pause.isEnabled); XCTAssertEqual(pause.action, .pauseOtherProtection(duration: nil, target: .headTurn))
        let stronger = try XCTUnwrap(document.rules.first { $0.guards.contains(.appCondition(bundleID: "example.editor")) })
        XCTAssertEqual(stronger.action, .blur(BlurParameters(radius: 60, comfort: 8, transition: 12), peek: nil))
        XCTAssertEqual(document.preferences.defaultBlur, BlurParameters(radius: 60, comfort: 20, transition: 25))
        XCTAssertNil(document.preferences.recenterShortcut)
        let appearance = try XCTUnwrap(try PropertyListSerialization.propertyList(from: document.preferences.appearance, format: nil) as? [String: Any])
        XCTAssertEqual(appearance["nearbyCameraID"] as? String, "camera-id")
        XCTAssertEqual(appearance["nearbyPauseUntil"] as? Date, legacy["nearbyPauseUntil"] as? Date)
        let data = try XCTUnwrap(storage.values[ProtectionStore.documentKey] as? Data)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private title"))
        XCTAssertEqual(try JSONDecoder().decode(ProtectionDocument.self, from: data), document)
        for key in legacy.keys { XCTAssertTrue(NSDictionary(dictionary: [key: storage.values[key]!]).isEqual(to: [key: legacy[key]!]), key) }
    }

    func testShortcutsStartEmptyAndExistingShortcutsAreClearedOnlyOnce() throws {
        let storage = MemoryProtectionPreferences(); let store = ProtectionStore(storage: storage)
        var document = try store.loadOrMigrate()
        XCTAssertNil(document.preferences.recenterShortcut); XCTAssertNil(document.preferences.regionSelectionShortcut)
        XCTAssertTrue(ShortcutRegistry(rules: document.rules).bindings.isEmpty)
        let chord = ShortcutBinding(keyCode: 13, modifiers: 4096, label: "⌃W")
        document.rules[0].trigger = .manual(shortcut: chord); document.rules[0].action = .blur(BlurParameters(), peek: .hold(chord))
        document.preferences.recenterShortcut = chord; document.preferences.regionSelectionShortcut = chord
        document.preferences.shortcutDefaultsVersion = 0; try store.save(document)
        let originalIDs = document.rules.map(\.id)
        document = try store.loadOrMigrate()
        XCTAssertEqual(document.rules.map(\.id), originalIDs)
        XCTAssertNil(document.preferences.recenterShortcut); XCTAssertNil(document.preferences.regionSelectionShortcut)
        XCTAssertTrue(ShortcutRegistry(rules: document.rules).bindings.isEmpty)
        document.rules[0].trigger = .manual(shortcut: chord); document.preferences.regionSelectionShortcut = chord
        try store.save(document)
        XCTAssertEqual(try store.loadOrMigrate(), document, "A new manually assigned shortcut must survive later launches")
    }

    func testRepeatedMigrationDoesNotDuplicateOrChangeIDsAndIgnoresOldWrites() throws {
        let storage = MemoryProtectionPreferences(["nearbyEnabled": true])
        let store = ProtectionStore(storage: storage)
        let first = try store.loadOrMigrate()
        let data = storage.values[ProtectionStore.documentKey] as? Data
        storage.values["nearbyEnabled"] = false
        for _ in 0..<4 { XCTAssertEqual(try store.loadOrMigrate(), first) }
        XCTAssertEqual(storage.values[ProtectionStore.documentKey] as? Data, data)
    }

    func testPartialCorruptionBacksUpAndRollsBackWithoutSilentlyDroppingProtection() throws {
        for damaged in [
            ["privacyAppRules": Data("damaged".utf8)],
            ["privacySavedAreas": Data("[]oops".utf8)],
            ["nearbyResponse": "unknown"],
            ["privacyCustomPhrases": 42],
            ["blur": "not a number"],
            ["privacyScanOptions": 128]
        ] as [[String: Any]] {
            let storage = MemoryProtectionPreferences(damaged.merging(["nearbyEnabled": true]) { old, _ in old })
            let original = NSDictionary(dictionary: storage.values)
            let store = ProtectionStore(storage: storage)
            XCTAssertThrowsError(try store.loadOrMigrate())
            XCTAssertNil(storage.values[ProtectionStore.documentKey])
            let backup = try XCTUnwrap(storage.values[ProtectionStore.backupKey] as? Data)
            let snapshot = try XCTUnwrap(try PropertyListSerialization.propertyList(from: backup, format: nil) as? [String: Any])
            XCTAssertTrue(original.isEqual(to: snapshot))
            let legacy = storage.values.filter { $0.key != ProtectionStore.backupKey }
            XCTAssertTrue(original.isEqual(to: legacy))
            XCTAssertThrowsError(try store.loadOrMigrate())
            XCTAssertEqual(storage.values[ProtectionStore.backupKey] as? Data, backup)
        }
    }

    func testCommitFailureLeavesLegacyIntactAndFailedEditPreservesExistingDocument() throws {
        let storage = MemoryProtectionPreferences(["nearbyEnabled": true])
        let store = ProtectionStore(storage: storage)
        storage.rejectDocumentWrites = true
        XCTAssertThrowsError(try store.loadOrMigrate())
        XCTAssertNil(storage.values[ProtectionStore.documentKey]); XCTAssertEqual(storage.values["nearbyEnabled"] as? Bool, true)
        storage.rejectDocumentWrites = false
        var document = try store.loadOrMigrate()
        let original = storage.values[ProtectionStore.documentKey] as? Data
        document.rules[0].name = "Changed"
        storage.rejectDocumentWrites = true
        XCTAssertThrowsError(try store.save(document))
        XCTAssertEqual(storage.values[ProtectionStore.documentKey] as? Data, original)
    }

    func testInvalidSchemaOrRuleNeverOverwritesExistingDocument() throws {
        let storage = MemoryProtectionPreferences()
        let store = ProtectionStore(storage: storage)
        var document = try store.loadOrMigrate()
        let original = storage.values[ProtectionStore.documentKey] as? Data
        document.schemaVersion = 2
        XCTAssertThrowsError(try store.save(document))
        document.schemaVersion = 1; document.rules[0].scope = .detectedText
        XCTAssertThrowsError(try store.save(document))
        XCTAssertEqual(storage.values[ProtectionStore.documentKey] as? Data, original)
        storage.values[ProtectionStore.documentKey] = Data("corrupt".utf8)
        XCTAssertThrowsError(try store.loadOrMigrate())
        XCTAssertEqual(storage.values[ProtectionStore.documentKey] as? Data, Data("corrupt".utf8))
    }

    func testMigrationReadsRealPreferenceCopyWithoutWritingOriginal() throws {
        guard let path = ProcessInfo.processInfo.environment["QUIETGLASS_MIGRATION_PREFS_PATH"] else {
            throw XCTSkip("Set QUIETGLASS_MIGRATION_PREFS_PATH to a private copy of the real preference plist.")
        }
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        let values = try XCTUnwrap(try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        let storage = MemoryProtectionPreferences(values)
        let store = ProtectionStore(storage: storage)
        let migrated = try store.loadOrMigrate()
        XCTAssertEqual(try store.loadOrMigrate(), migrated)
        XCTAssertTrue(migrated.rules.allSatisfy { ProtectionRuleValidator.validate($0).isEmpty })
        XCTAssertEqual(try Data(contentsOf: url), original)
        for key in ProtectionStore.legacyKeys where values[key] != nil {
            XCTAssertTrue(NSDictionary(dictionary: [key: storage.values[key]!]).isEqual(to: [key: values[key]!]), key)
        }
        // Compare enabled detector and nearby behavior with the real copy, not generated fixtures.
        if storage.values[ProtectionStore.backupKey] != nil {
            let enabled = values["nearbyEnabled"] as? Bool ?? false
            XCTAssertEqual(migrated.rules.first { if case .extraFace = $0.trigger { return true }; return false }?.isEnabled, enabled)
        }
    }
}
