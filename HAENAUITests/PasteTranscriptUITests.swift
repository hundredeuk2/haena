import XCTest

@MainActor
final class PasteTranscriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPasteTranscriptButtonOpensInputScreen() throws {
        let app = try AppShellUITests.guardedLaunch(for: self)
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        app.buttons["paste-transcript-button"].click()
        try AppShellUITests.validateEnvironment(app)

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["meeting-title-field"].value as? String, "")
        XCTAssertEqual(app.textViews["transcript-text-editor"].value as? String, "")
        try AppShellUITests.validateEnvironment(app)
    }

    func testSavingWithoutProjectShowsValidationMessage() throws {
        let app = try AppShellUITests.guardedLaunch(for: self)
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        app.buttons["paste-transcript-button"].click()
        try AppShellUITests.validateEnvironment(app)

        XCTAssertTrue(app.buttons["save-text-meeting-button"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        app.buttons["save-text-meeting-button"].click()
        try AppShellUITests.validateEnvironment(app)

        XCTAssertTrue(app.staticTexts["text-meeting-validation-message"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
    }

    func testCreatingProjectAndSavingMeetingShowsSavedConfirmation() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = "ko"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 5))
        app.buttons["paste-transcript-button"].click()

        // Each element is re-queried fresh immediately before use (no cached `let` bindings
        // held across intervening actions) — SwiftUI re-renders this form as fields are
        // edited, and a stale cached element snapshot from an earlier query can fail to
        // resolve by the time a later action runs.
        XCTAssertTrue(app.buttons["new-project-button"].waitForExistence(timeout: 5))
        app.buttons["new-project-button"].click()

        XCTAssertTrue(app.textFields["new-project-name-field"].waitForExistence(timeout: 5))
        app.textFields["new-project-name-field"].click()
        app.textFields["new-project-name-field"].typeText("HAE.NA UI Test Project")

        app.buttons["create-project-button"].click()

        // Wait for the now-project-name row to actually disappear (it's conditionally shown)
        // before touching anything below it — otherwise that layout collapse can still be in
        // flight when the next click resolves its element snapshot, making the click flaky.
        let nameFieldRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["new-project-name-field"]
        )
        wait(for: [nameFieldRemoved], timeout: 5)

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
        app.textFields["meeting-title-field"].click()
        app.textFields["meeting-title-field"].typeText("Kickoff Meeting")

        XCTAssertTrue(app.textViews["transcript-text-editor"].waitForExistence(timeout: 5))
        app.textViews["transcript-text-editor"].click()
        app.textViews["transcript-text-editor"].typeText("Decisions made in today's meeting.")

        app.buttons["save-text-meeting-button"].click()

        XCTAssertTrue(app.staticTexts["text-meeting-saved-message"].waitForExistence(timeout: 5))
    }

    func testStructuredPasteLinksOneSpeakerKeepsAnotherUnlinkedAndReachesCompletion() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = "ko"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 5))
        app.buttons["paste-transcript-button"].click()
        XCTAssertTrue(app.buttons["new-project-button"].waitForExistence(timeout: 5))
        app.buttons["new-project-button"].click()
        XCTAssertTrue(app.textFields["new-project-name-field"].waitForExistence(timeout: 5))
        app.textFields["new-project-name-field"].click()
        app.textFields["new-project-name-field"].typeText("Structured Paste UI Project")
        app.textFields["new-project-name-field"].typeKey(.return, modifierFlags: [])

        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["new-project-name-field"]
        )
        wait(for: [removed], timeout: 5)

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
        app.textFields["meeting-title-field"].click()
        app.textFields["meeting-title-field"].typeText("Structured Paste Meeting")
        selectSegment(
            "화자 구조화",
            inPickerWithIdentifier: "pasted-transcript-input-mode-picker",
            of: app
        )

        XCTAssertTrue(scrollTo(app.textFields["pasted-participant-name-field"], in: app))
        app.textFields["pasted-participant-name-field"].click()
        app.textFields["pasted-participant-name-field"].typeText("Participant A")
        app.textFields["pasted-participant-name-field"].typeKey(.return, modifierFlags: [])

        XCTAssertTrue(scrollTo(app.textFields["pasted-speaker-label-field-0"], in: app))
        app.textFields["pasted-speaker-label-field-0"].click()
        app.textFields["pasted-speaker-label-field-0"].typeText("A")
        app.textViews["pasted-turn-text-editor-0"].click()
        app.textViews["pasted-turn-text-editor-0"].typeText("I will prepare the draft.")

        XCTAssertTrue(scrollTo(app.buttons["add-pasted-turn-button"], in: app))
        app.buttons["add-pasted-turn-button"].click()
        app.buttons["show-pasted-turns-button"].click()
        XCTAssertTrue(scrollTo(app.textFields["pasted-speaker-label-field-1"], in: app))
        app.textFields["pasted-speaker-label-field-1"].click()
        app.textFields["pasted-speaker-label-field-1"].typeText("C")
        app.textViews["pasted-turn-text-editor-1"].click()
        app.textViews["pasted-turn-text-editor-1"].typeText("This speaker remains unlinked.")

        XCTAssertTrue(app.buttons["show-pasted-speaker-links-button"].waitForExistence(timeout: 5))
        app.buttons["show-pasted-speaker-links-button"].click()

        XCTAssertTrue(selectPopup(
            "Participant A",
            withIdentifier: "pasted-speaker-link-picker-0",
            in: app
        ))
        XCTAssertTrue(staticText("A → Participant A", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(staticText("C → 미연결", in: app).waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["save-text-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["save-text-meeting-button"].click()

        XCTAssertTrue(app.staticTexts["text-meeting-saved-message"].waitForExistence(timeout: 8))
    }

    private func selectSegment(
        _ label: String,
        inPickerWithIdentifier identifier: String,
        of app: XCUIApplication
    ) {
        let picker = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let radio = picker.radioButtons[label]
        if radio.waitForExistence(timeout: 2) {
            radio.click()
        } else {
            let button = picker.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            button.click()
        }
    }

    private func selectPopup(
        _ label: String,
        withIdentifier identifier: String,
        in app: XCUIApplication
    ) -> Bool {
        let picker = app.descendants(matching: .any)[identifier]
        guard picker.waitForExistence(timeout: 5) else { return false }
        let radio = picker.radioButtons[label]
        guard radio.waitForExistence(timeout: 5) else { return false }
        app.activate()
        radio.click()
        return true
    }

    private func staticText(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        if target.waitForExistence(timeout: 1), target.isHittable { return true }
        app.activate()
        let scrollView = app.scrollViews["paste-transcript-scroll"]
        guard scrollView.waitForExistence(timeout: 2) else { return target.exists }
        for _ in 0..<24 {
            let delta = target.exists && target.frame.midY < scrollView.frame.midY ? 200.0 : -200.0
            scrollView.scroll(byDeltaX: 0, deltaY: delta)
            if target.waitForExistence(timeout: 0.5), target.isHittable { return true }
        }
        return target.exists && target.isHittable
    }
}
