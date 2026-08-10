import XCTest

@MainActor
final class ActionItemReminderSampleUITests: XCTestCase {
    private let sampleActionItemID = "A6000000-0000-4000-8000-000000000005"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreatesSampleAndOpensEligibleReminderTask() {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launch()

        let createButton = app.buttons["create-reminder-sample-button"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        let reminderButton = app.buttons["action-item-reminder-\(sampleActionItemID)"]
        XCTAssertTrue(
            reminderButton.waitForExistence(timeout: 5),
            "The sample should open on a confirmed own task that exposes reminder setup"
        )
        XCTAssertTrue(reminderButton.isHittable)

        let guidance = app.staticTexts["highlighted-reminder-guidance"]
        XCTAssertTrue(
            guidance.waitForExistence(timeout: 2),
            "The opened sample should explain where its reminder is configured"
        )

        reminderButton.click()
        XCTAssertTrue(
            app.datePickers["action-item-reminder-date-picker"].waitForExistence(timeout: 3),
            "The visible reminder action should open the scheduling sheet"
        )
    }
}
