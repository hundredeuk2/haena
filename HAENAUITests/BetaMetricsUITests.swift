import XCTest

@MainActor
final class BetaMetricsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Integration contract for the 베타 측정 sheet.
    ///
    /// The app owner wires both the entry button and a deterministic `HAENA_UI_TESTING_BETA_METRICS`
    /// seed. Keeping the whole journey in one test is what stops the screen's rate denominators, its
    /// 측정 기준 explanation, and its destructive confirmation from being integrated as separate
    /// pieces that are never exercised together — the empty state at the end is only trustworthy
    /// because it follows a run that actually had numbers in it.
    func testOpensMetricsReadsCriteriaAndResetsAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TESTING_BETA_METRICS"] = "1"
        app.launch()

        let entryButton = app.buttons["open-beta-metrics-button"]
        XCTAssertTrue(
            entryButton.waitForExistence(timeout: 5),
            "베타 측정 진입점과 HAENA_UI_TESTING_BETA_METRICS seed가 함께 연결되어야 합니다."
        )
        entryButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["beta-metrics-screen"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["beta-metrics-list"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["beta-metrics-empty-state"].exists,
            "seed가 있으면 신규 설치 빈 상태가 아니어야 합니다."
        )

        // The seeded run must show a real rate, and the rate must never appear without the counts
        // it was computed from.
        let approvalRate = app.staticTexts["beta-metrics-value-approval-rate"]
        XCTAssertTrue(approvalRate.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayedText(of: approvalRate).contains("%"),
            "seed된 승인율이 표시되어야 합니다."
        )
        let approvalDetail = app.staticTexts["beta-metrics-detail-approval-rate"]
        XCTAssertTrue(approvalDetail.exists)
        XCTAssertTrue(
            displayedText(of: approvalDetail).contains("/"),
            "승인율은 분자/분모와 함께 표시되어야 합니다."
        )

        let criteriaToggle = app.buttons["beta-metrics-criteria-toggle"]
        XCTAssertTrue(criteriaToggle.exists)
        criteriaToggle.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["beta-metrics-criteria"].waitForExistence(timeout: 2)
        )
        let measurementWindow = app.staticTexts["beta-metrics-criteria-7"]
        XCTAssertTrue(measurementWindow.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayedText(of: measurementWindow).contains("0.2.2"),
            "측정 기준에는 0.2.2부터만 집계한다는 설명이 있어야 합니다."
        )
        criteriaToggle.click()

        let resetButton = app.buttons["reset-beta-metrics-button"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 2))
        XCTAssertTrue(resetButton.isHittable)
        resetButton.click()

        let confirmation = app.descendants(matching: .any)["beta-metrics-reset-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["confirm-reset-beta-metrics-button"].click()

        XCTAssertTrue(
            app.descendants(matching: .any)["beta-metrics-empty-state"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            displayedText(of: app.staticTexts["beta-metrics-value-approval-rate"]),
            "표본 없음",
            "초기화 뒤의 승인율은 0%가 아니라 빈 상태여야 합니다."
        )
    }

    private func displayedText(of element: XCUIElement) -> String {
        element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }
}
