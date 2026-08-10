import XCTest

@MainActor
final class AgentLedgerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Integration contract for the Agent record sheet.
    ///
    /// The app owner wires both the entry button and a deterministic
    /// `HAENA_UI_TESTING_AGENT_LEDGER` seed. Keeping the complete journey here prevents the sheet's
    /// narrow-window actions, conservative wording, feedback controls, and destructive confirmation
    /// from being integrated as unrelated pieces that are never exercised together.
    func testOpensLedgerRecordsFeedbackAndDeletesAllAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TESTING_AGENT_LEDGER"] = "1"
        app.launch()

        let entryButton = app.buttons["open-agent-ledger-button"]
        XCTAssertTrue(
            entryButton.waitForExistence(timeout: 5),
            "Agent 기록 진입점과 HAENA_UI_TESTING_AGENT_LEDGER seed가 함께 연결되어야 합니다."
        )
        entryButton.click()

        XCTAssertTrue(app.otherElements["agent-ledger-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["agent-ledger-event-list"].exists)
        let seededFact = app.staticTexts["agent-ledger-event-fact-label"].firstMatch.label
        XCTAssertTrue(
            seededFact.hasPrefix("예약 시각 지남"),
            "The fireTimeReached seed must state only that its approved time passed."
        )

        let helpful = app.buttons["agent-ledger-feedback-helpful"].firstMatch
        XCTAssertTrue(helpful.waitForExistence(timeout: 2))
        helpful.click()
        waitForValue("선택됨", of: helpful)

        helpful.click()
        waitForValue("선택 안 됨", of: helpful)

        let deleteButton = app.buttons["delete-all-agent-ledger-button"]
        XCTAssertTrue(deleteButton.isHittable)
        deleteButton.click()
        let confirmation = app.otherElements["delete-agent-ledger-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["confirm-delete-all-agent-ledger-button"].click()

        XCTAssertTrue(app.otherElements["agent-ledger-empty-state"].waitForExistence(timeout: 3))
    }

    private func waitForValue(_ value: String, of element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }
}
