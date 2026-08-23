import XCTest

@MainActor
final class ProjectDeletionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// On macOS, AXStaticText exposes its displayed text via the `value` attribute rather than
    /// `label` — same quirk documented in `HAENAUITests.testHomeScreenShowsProductName`.
    private func staticText(_ app: XCUIApplication, withValue value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// Creates a project + meeting through the existing pasted-transcript flow (ASCII input
    /// avoids the macOS IME/input-source picker Korean `typeText` can trigger), then opens the
    /// project browser and selects the project row so its detail pane is showing.
    private func createProjectAndOpenDetail(
        app: XCUIApplication,
        projectName: String,
        meetingTitle: String,
        transcript: String
    ) {
        app.buttons["paste-transcript-button"].click()

        XCTAssertTrue(app.buttons["new-project-button"].waitForExistence(timeout: 5))
        app.buttons["new-project-button"].click()

        XCTAssertTrue(app.textFields["new-project-name-field"].waitForExistence(timeout: 5))
        app.textFields["new-project-name-field"].click()
        app.textFields["new-project-name-field"].typeText(projectName)
        app.buttons["create-project-button"].click()

        let nameFieldRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["new-project-name-field"]
        )
        wait(for: [nameFieldRemoved], timeout: 5)

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
        app.textFields["meeting-title-field"].click()
        app.textFields["meeting-title-field"].typeText(meetingTitle)

        XCTAssertTrue(app.textViews["transcript-text-editor"].waitForExistence(timeout: 5))
        app.textViews["transcript-text-editor"].click()
        app.textViews["transcript-text-editor"].typeText(transcript)

        app.buttons["save-text-meeting-button"].click()
        XCTAssertTrue(app.staticTexts["text-meeting-saved-message"].waitForExistence(timeout: 5))

        app.buttons["cancel-text-meeting-button"].click()

        XCTAssertTrue(app.buttons["browse-projects-button"].waitForExistence(timeout: 5))
        app.buttons["browse-projects-button"].click()

        let projectList = app.descendants(matching: .any)["project-list"]
        XCTAssertTrue(projectList.waitForExistence(timeout: 5))
        let projectNameText = projectList.staticTexts.matching(
            NSPredicate(format: "value == %@", projectName)
        ).firstMatch
        XCTAssertTrue(projectNameText.waitForExistence(timeout: 5))
        projectNameText.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["project-detail-screen"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["delete-project-button"].waitForExistence(timeout: 5))
    }

    // MARK: - Project deletion

    func testCancelingProjectDeletionKeepsProjectVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        createProjectAndOpenDetail(
            app: app,
            projectName: "Cancel Delete Project",
            meetingTitle: "Meeting",
            transcript: "Body text."
        )

        app.buttons["delete-project-button"].click()

        XCTAssertTrue(app.buttons["cancel-delete-project-button"].waitForExistence(timeout: 5))
        app.buttons["cancel-delete-project-button"].click()

        let projectNameText = staticText(app, withValue: "Cancel Delete Project")
        XCTAssertTrue(projectNameText.waitForExistence(timeout: 5))
    }

    func testConfirmingProjectDeletionRemovesItAndShowsEmptyState() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        createProjectAndOpenDetail(
            app: app,
            projectName: "Confirm Delete Project",
            meetingTitle: "Meeting",
            transcript: "Body text."
        )

        app.buttons["delete-project-button"].click()

        XCTAssertTrue(app.buttons["confirm-delete-project-button"].waitForExistence(timeout: 5))
        app.buttons["confirm-delete-project-button"].click()

        XCTAssertTrue(app.groups["project-browser-empty-state"].waitForExistence(timeout: 5))
    }

    // MARK: - Meeting deletion

    func testCancelingMeetingDeletionKeepsMeetingVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        createProjectAndOpenDetail(
            app: app,
            projectName: "Cancel Delete Meeting Project",
            meetingTitle: "Cancel Delete Meeting",
            transcript: "Body text."
        )

        selectMeetingsPane(in: app)

        let meetingTitleText = staticText(app, withValue: "Cancel Delete Meeting")
        XCTAssertTrue(meetingTitleText.waitForExistence(timeout: 5))
        meetingTitleText.click()

        XCTAssertTrue(app.buttons["delete-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["delete-meeting-button"].click()

        XCTAssertTrue(app.buttons["cancel-delete-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["cancel-delete-meeting-button"].click()

        let detailTitle = app.staticTexts["meeting-detail-title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(detailTitle.value as? String, "Cancel Delete Meeting")
    }

    func testConfirmingMeetingDeletionRemovesItAndShowsEmptyStateWhileProjectRemains() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        createProjectAndOpenDetail(
            app: app,
            projectName: "Confirm Delete Meeting Project",
            meetingTitle: "Confirm Delete Meeting",
            transcript: "Body text."
        )

        selectMeetingsPane(in: app)

        let meetingTitleText = staticText(app, withValue: "Confirm Delete Meeting")
        XCTAssertTrue(meetingTitleText.waitForExistence(timeout: 5))
        meetingTitleText.click()

        XCTAssertTrue(app.buttons["delete-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["delete-meeting-button"].click()

        XCTAssertTrue(app.buttons["confirm-delete-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["confirm-delete-meeting-button"].click()

        // The repository reload may rebuild the project pane at its default status tab. Return to
        // 회의 explicitly, then verify the deleted meeting did not leave a phantom row.
        selectMeetingsPane(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["meeting-list-empty-state"]
                .waitForExistence(timeout: 5)
        )
        let projectNameText = staticText(app, withValue: "Confirm Delete Meeting Project")
        XCTAssertTrue(projectNameText.waitForExistence(timeout: 5))
    }

    private func selectMeetingsPane(in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["project-detail-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let radio = picker.radioButtons["회의"]
        if radio.waitForExistence(timeout: 2) {
            radio.click()
        } else {
            let button = picker.buttons["회의"]
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            button.click()
        }
    }
}
