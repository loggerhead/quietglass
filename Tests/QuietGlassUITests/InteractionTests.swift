import XCTest

/// Uses the accessibility tree, not screenshot OCR or text-derived click coordinates.
final class InteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["QUIETGLASS_TEST_DESKTOP"].map({ ["isolated", "interactive"].contains($0) }) == true else {
            throw NSError(domain: "QuietGlass.UITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Use scripts/test-desktop.sh with --interactive or --isolated."])
        }
        app = XCUIApplication()
        app.launchEnvironment["QUIETGLASS_TEST_DESKTOP"] = ProcessInfo.processInfo.environment["QUIETGLASS_TEST_DESKTOP"]!
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws { app?.terminate(); app = nil }

    private func launch(_ arguments: [String] = []) { app.launchArguments += arguments; app.launch() }
    private func element(_ identifier: String) -> XCUIElement {
        let value = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 10), "Missing accessibility element: \(identifier)")
        return value
    }
    private func button(_ label: String, in scope: XCUIElement? = nil) -> XCUIElement {
        let value = (scope ?? app).buttons[label].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 10), "Missing button: \(label)")
        return value
    }

    func testNavigationAndManualBlur() {
        launch()
        element("navigation.rules").click()
        element("rules.new")
        element("navigation.settings").click()
        XCTAssertTrue(app.staticTexts["Permissions and calibration"].firstMatch.waitForExistence(timeout: 10))
        element("navigation.protection").click()
        button("Blur all displays").click()
        XCTAssertEqual(element("fixture.coverage").label, "blurred")
        button("Blur all displays").click()
        XCTAssertEqual(element("fixture.coverage").label, "clear")
    }

    func testPresetRepeatReusesIdentity() {
        launch(["--rules"])
        button("Respond to nearby people").click()
        let count = element("fixture.rule-count").label
        let id = element("fixture.preset-id").label
        XCTAssertNotEqual(id, "none")
        // Navigation returns to the top without guessing where the preset moved.
        element("navigation.protection").click(); element("navigation.rules").click()
        let preset = button("Respond to nearby people")
        if !preset.isHittable { app.scrollViews.firstMatch.swipeDown() }
        preset.click()
        XCTAssertEqual(element("fixture.rule-count").label, count)
        XCTAssertEqual(element("fixture.preset-id").label, id)
    }

    func testEditingKeepsTheOriginalRule() {
        launch(["--rules"])
        button("Edit…").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let field = sheet.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText("Saved nearby revised")
        button("Next", in: sheet).click(); button("Next", in: sheet).click(); button("Save rule", in: sheet).click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertEqual(element("fixture.rule-count").label, "1")
        XCTAssertEqual(element("fixture.saved-id").label, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(element("fixture.saved-name").label, "Saved nearby revised")
    }

    func testRegionSelectionDoesNotSaveUntilConfirmed() {
        launch(["--rules"])
        button("Edit…").click()
        let sheet = app.sheets.firstMatch
        button("Next", in: sheet).click()
        element("rule.select-region").click()
        XCTAssertEqual(element("fixture.rule-count").label, "1")
        XCTAssertEqual(element("fixture.coverage").label, "clear")
        button("Next", in: sheet).click(); button("Save rule", in: sheet).click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertEqual(element("fixture.saved-id").label, "11111111-2222-3333-4444-555555555555")
    }

    func testNotchScopeMenuDoesNotActivateBlurUntilSelected() {
        launch(["--notch"])
        button("Settings").click()
        XCTAssertEqual(element("fixture.last-action").label, "settings")
        button("Choose content…").click()
        XCTAssertEqual(element("fixture.coverage").label, "clear")
        button("Blur all displays").click()
        XCTAssertEqual(element("fixture.coverage").label, "blurred")
    }

    func testCompactNotchUsesAccessibleControls() {
        launch(["--compact-notch"])
        element("Automatic detection").click()
        XCTAssertEqual(element("fixture.last-action").label, "automaticDetection")
        button("Settings").click()
        XCTAssertEqual(element("fixture.last-action").label, "settings")
        button("Choose content…").click()
        XCTAssertEqual(element("fixture.last-action").label, "area")
    }
}
