import XCTest

@MainActor
final class ProjectBrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// On macOS, AXStaticText exposes its displayed text via the `value` attribute rather than
    /// `label` — same quirk documented in `HAENAUITests.testHomeScreenShowsProductName`.
    private func staticText(_ app: XCUIApplication, withValue value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    func testEmptyStateShowsMessage() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["browse-projects-button"].waitForExistence(timeout: 5))
        app.buttons["browse-projects-button"].click()

        XCTAssertTrue(app.groups["project-browser-empty-state"].waitForExistence(timeout: 5))
    }

    func testCreatingMeetingThenBrowsingShowsProjectAndMeetingDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        // Create a project + meeting through the existing pasted-transcript flow. ASCII input
        // avoids the macOS IME/input-source picker that Korean `typeText` input can trigger.
        app.buttons["paste-transcript-button"].click()

        XCTAssertTrue(app.buttons["new-project-button"].waitForExistence(timeout: 5))
        app.buttons["new-project-button"].click()

        XCTAssertTrue(app.textFields["new-project-name-field"].waitForExistence(timeout: 5))
        app.textFields["new-project-name-field"].click()
        app.textFields["new-project-name-field"].typeText("Browser Test Project")
        app.buttons["create-project-button"].click()

        let nameFieldRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["new-project-name-field"]
        )
        wait(for: [nameFieldRemoved], timeout: 5)

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
        app.textFields["meeting-title-field"].click()
        app.textFields["meeting-title-field"].typeText("Browser Test Meeting")

        XCTAssertTrue(app.textViews["transcript-text-editor"].waitForExistence(timeout: 5))
        app.textViews["transcript-text-editor"].click()
        app.textViews["transcript-text-editor"].typeText("Browser test transcript body.")

        app.buttons["save-text-meeting-button"].click()
        XCTAssertTrue(app.staticTexts["text-meeting-saved-message"].waitForExistence(timeout: 5))

        app.buttons["cancel-text-meeting-button"].click()

        // Browse to the project we just created.
        XCTAssertTrue(app.buttons["browse-projects-button"].waitForExistence(timeout: 5))
        app.buttons["browse-projects-button"].click()

        let projectNameText = staticText(app, withValue: "Browser Test Project")
        XCTAssertTrue(projectNameText.waitForExistence(timeout: 5))

        let meetingCountText = staticText(app, withValue: "회의 1개")
        XCTAssertTrue(meetingCountText.waitForExistence(timeout: 5))

        projectNameText.click()

        // A project opens on 현재 상태, so the meeting list is one tab over.
        selectSegment("회의", inPickerWithIdentifier: "project-detail-pane-picker", of: app)

        // Select the meeting from the project's meeting list.
        let meetingTitleText = staticText(app, withValue: "Browser Test Meeting")
        XCTAssertTrue(meetingTitleText.waitForExistence(timeout: 5))
        meetingTitleText.click()

        // Meeting detail: title, source type, and — by default — what the meeting produced.
        let detailTitle = app.staticTexts["meeting-detail-title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(detailTitle.value as? String, "Browser Test Meeting")

        let sourceType = app.staticTexts["meeting-detail-source-type"]
        XCTAssertTrue(sourceType.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceType.value as? String, "텍스트 입력")

        let results = app.descendants(matching: .any)["meeting-results-screen"]
        XCTAssertTrue(results.waitForExistence(timeout: 5), "A meeting opens on its results")

        // The transcript is still there, one tab over, unchanged.
        selectSegment("원문", inPickerWithIdentifier: "meeting-detail-pane-picker", of: app)

        let transcriptBody = staticText(app, withValue: "Browser test transcript body.")
        XCTAssertTrue(transcriptBody.waitForExistence(timeout: 5))
    }

    /// Clicks one segment of a segmented `Picker`. AppKit exposes those segments as radio buttons
    /// in some contexts and as buttons in others, so both are tried rather than guessed at.
    private func selectSegment(
        _ label: String,
        inPickerWithIdentifier identifier: String,
        of app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Picker \(identifier) never appeared",
            file: file,
            line: line
        )

        let radio = picker.radioButtons[label]
        if radio.waitForExistence(timeout: 2) {
            radio.click()
            return
        }

        let button = picker.buttons[label]
        XCTAssertTrue(
            button.waitForExistence(timeout: 2),
            "Segment \(label) never appeared in \(identifier)",
            file: file,
            line: line
        )
        button.click()
    }
}
