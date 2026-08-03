import XCTest

@MainActor
final class PasteTranscriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPasteTranscriptButtonOpensInputScreen() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["paste-transcript-button"].waitForExistence(timeout: 5))
        app.buttons["paste-transcript-button"].click()

        XCTAssertTrue(app.textFields["meeting-title-field"].waitForExistence(timeout: 5))
    }

    func testSavingWithoutProjectShowsValidationMessage() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["paste-transcript-button"].click()

        XCTAssertTrue(app.buttons["save-text-meeting-button"].waitForExistence(timeout: 5))
        app.buttons["save-text-meeting-button"].click()

        XCTAssertTrue(app.staticTexts["text-meeting-validation-message"].waitForExistence(timeout: 5))
    }

    func testCreatingProjectAndSavingMeetingShowsSavedConfirmation() {
        let app = XCUIApplication()
        app.launch()

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
}
