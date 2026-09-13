import XCTest

@MainActor
final class AppLanguageUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ language: String, brief: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = language
        if brief { app.launchEnvironment["HAENA_UI_TESTING_MANUAL_BRIEF"] = "1" }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 8))
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        // Capture this app's window, not the main display (which may contain another app).
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settings(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["app-language-picker"].waitForExistence(timeout: 5))
    }

    private func choose(_ app: XCUIApplication, _ name: String) {
        let picker = app.popUpButtons["app-language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems[name].click()
    }

    func testEnglishHomeAndAISettings() {
        let app = launch("en")
        XCTAssertEqual(app.buttons["paste-transcript-button"].label, "Paste Transcript")
        XCTAssertTrue(app.buttons["paste-transcript-button"].isHittable)
        screenshot(app, "English Home")
        app.buttons["open-ai-settings-button"].click()
        XCTAssertTrue(app.staticTexts["openai-credential-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["openai-credential-status"].value as? String, "Not configured")
        XCTAssertTrue(app.buttons["close-ai-settings-button"].isHittable)
        screenshot(app, "English AI Guidance")
    }

    func testKoreanHomeAndSettings() {
        let app = launch("ko")
        XCTAssertEqual(app.buttons["paste-transcript-button"].label, "텍스트 회의록 붙여넣기")
        screenshot(app, "Korean Home")
        settings(app)
        screenshot(app, "Korean General Settings")
        XCTAssertTrue(app.staticTexts["effective-app-language"].exists)
    }

    func testSwitchPreservesUnsavedDraftAndValidation() {
        let app = launch("ko")
        app.buttons["paste-transcript-button"].click()
        let title = app.textFields["meeting-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click(); title.typeText("Synthetic unchanged title")
        let text = app.textViews["transcript-text-editor"]
        text.click(); text.typeText("Synthetic unchanged source text")
        let enteredTitle = title.value as? String
        let enteredText = text.value as? String
        XCTAssertFalse(enteredTitle?.isEmpty ?? true)
        XCTAssertFalse(enteredText?.isEmpty ?? true)
        app.buttons["save-text-meeting-button"].click()
        XCTAssertTrue(app.staticTexts["text-meeting-validation-message"].waitForExistence(timeout: 5))
        settings(app)
        choose(app, "English")
        screenshot(app, "English General Settings During Draft")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.textFields["meeting-title-field"].value as? String, enteredTitle)
        XCTAssertEqual(app.textViews["transcript-text-editor"].value as? String, enteredText)
        XCTAssertEqual(app.buttons["save-text-meeting-button"].label, "Save")
        XCTAssertEqual(app.staticTexts["text-meeting-validation-message"].value as? String, "Select a project or create a new one.")
        screenshot(app, "English Preserved Draft and Validation")
    }

    func testLanguageSelectionSurvivesNewProcessAndReturnsToSystem() {
        let app = XCUIApplication()
        let suite = "com.haena.ui-language-test.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE_SUITE"] = suite
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 8))
        settings(app); choose(app, "English")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["paste-transcript-button"].label, "Paste Transcript")
        settings(app); choose(app, "Use System Setting")
        screenshot(app, "Return to System Language")
    }

    func testSwitchKeepsDeterministicRecordingRunning() {
        let app = launch("ko")
        app.buttons["record-button"].click()
        XCTAssertTrue(app.buttons["start-recording-button"].waitForExistence(timeout: 5))
        app.buttons["start-recording-button"].click()
        XCTAssertTrue(app.buttons["stop-recording-button"].waitForExistence(timeout: 5))
        settings(app); choose(app, "English")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["stop-recording-button"].exists)
        XCTAssertFalse(app.buttons["start-recording-button"].exists)
        XCTAssertEqual(app.buttons["stop-recording-button"].label, "Stop Recording")
        screenshot(app, "English Running Recording")
        app.activate()
        app.buttons["cancel-recording-button"].click()
    }

    func testEnglishBriefSeparatesApprovedAndPendingWithoutChangingSelection() {
        let app = launch("en", brief: true)
        app.buttons["browse-projects-button"].click()
        let project = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-name-")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5)); project.click()
        let entry = app.buttons["open-manual-continuity-brief-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Confirmed State")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Changes to Review")).firstMatch.exists)
        screenshot(app, "English Continuity Brief")
        settings(app); choose(app, "한국어"); app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["manual-continuity-brief-screen"].exists)
        screenshot(app, "Korean Same Continuity Brief")
    }
}
