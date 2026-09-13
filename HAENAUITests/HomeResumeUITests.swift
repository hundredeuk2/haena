import XCTest

@MainActor
final class HomeResumeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String, _ language: String) throws -> XCUIApplication {
        let app = try AppShellUITests.guardedLaunch(for: self, language: language,
                                                   homeScenario: scenario, minimum: true)
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, 722)
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.height, 554)
        return app
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func visible(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(item.frame), "Must fit without scrolling")
    }

    private func click(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable)
        item.click()
        try AppShellUITests.validateEnvironment(app)
    }

    private func resumeLabel(_ language: String, pending: Bool) -> String {
        // SwiftUI exposes this navigation row as one accessible button, not child StaticTexts.
        let stage = pending ? (language == "ko" ? "저장 상태: 검토 필요" : "Saved state: review needed")
            : (language == "ko" ? "저장 상태: 검토할 제안 없음" : "Saved state: no proposals awaiting review")
        let count = language == "ko" ? "이 회의의 미검토 제안: \(pending ? 1 : 0)"
            : "Unreviewed proposals in this meeting: \(pending ? 1 : 0)"
        return [language == "ko" ? "최근 회의" : "Latest Meeting", "Synthetic Resume Meeting", stage, count]
            .joined(separator: ", ")
    }

    private func empty(_ language: String) throws {
        let app = try launch("empty", language); defer { app.terminate() }
        let purpose = app.staticTexts["home-purpose"]
        try visible(purpose, app)
        XCTAssertEqual(purpose.value as? String, language == "ko"
                       ? "회의를 남기고, 제안을 검토하고, 다음 할 일을 이어가세요."
                       : "Capture a meeting, review its suggestions, and continue your next task.")
        XCTAssertEqual(element("home-capture-actions", app).buttons.count, 3)
        XCTAssertFalse(app.buttons["home-next-action-button"].exists)
        XCTAssertFalse(app.buttons["open-agent-ledger-button"].exists)
        XCTAssertFalse(app.buttons["open-beta-metrics-button"].exists)
        for id in ["record-button", "import-button", "paste-transcript-button"] {
            try visible(app.buttons[id], app)
        }
        try click(app.buttons["record-button"], app)
        XCTAssertTrue(app.buttons["start-recording-button"].waitForExistence(timeout: 5))
        try click(app.buttons["close-recording-button"], app)
        try click(app.buttons["import-button"], app)
        XCTAssertTrue(app.buttons["choose-audio-file-button"].waitForExistence(timeout: 5))
        try click(app.buttons["cancel-audio-import-button"], app)
        try click(app.buttons["paste-transcript-button"], app)
        XCTAssertTrue(app.textViews["transcript-text-editor"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["transcript-text-editor"].value as? String, "")
        try click(app.buttons["cancel-text-meeting-button"], app)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(purpose.exists)
    }

    private func returning(_ scenario: String, _ language: String, pending: Bool) throws {
        let app = try launch(scenario, language); defer { app.terminate() }
        let primary = app.buttons["home-next-action-button"]
        try visible(primary, app)
        XCTAssertEqual(app.buttons.matching(identifier: "home-next-action-button").count, 1)
        XCTAssertEqual(primary.label, pending ? (language == "ko" ? "검토하기" : "Review")
                       : (language == "ko" ? "업무 보기" : "View Action Item"))
        try visible(app.buttons["home-latest-meeting-button"], app)
        XCTAssertEqual(app.buttons["home-latest-meeting-button"].label, resumeLabel(language, pending: pending))
        if !pending {
            XCTAssertEqual(app.staticTexts["home-next-action-headline"].value as? String, "Synthetic assigned follow-up")
            XCTAssertEqual(app.staticTexts["home-next-action-assignee"].value as? String, "Synthetic Participant")
        }
        XCTAssertFalse(element("home-pending-section", app).exists)
        try click(primary, app)
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        if pending {
            XCTAssertTrue(app.staticTexts["pending-proposal-count"].exists)
        } else {
            XCTAssertTrue(element("active-action-item-CA000000-0000-4000-8000-000000000005", app).exists)
        }
        try click(app.buttons["shell-rail-home"], app)
        try click(app.buttons["home-latest-meeting-button"], app)
        XCTAssertTrue(element("meeting-results-screen", app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Synthetic Resume Meeting")
    }

    private func noProfile(_ language: String) throws {
        let app = try launch("noProfile", language); defer { app.terminate() }
        try visible(app.staticTexts["home-next-action-empty"], app)
        XCTAssertFalse(app.buttons["home-next-action-button"].exists)
        XCTAssertTrue(element("home-next-action-profile-hint", app).exists)
        try visible(app.buttons["home-latest-meeting-button"], app)
        try click(app.buttons["home-latest-meeting-button"], app)
        XCTAssertTrue(element("meeting-results-screen", app).waitForExistence(timeout: 5))
    }

    private func failure(_ language: String) throws {
        let app = try launch("loadFailure", language); defer { app.terminate() }
        try visible(app.buttons["home-retry-button"], app)
        XCTAssertTrue(app.staticTexts["home-error-message"].exists)
        XCTAssertFalse(element("home-empty-state", app).exists)
        XCTAssertFalse(app.buttons["home-next-action-button"].exists)
        try click(app.buttons["home-retry-button"], app)
        XCTAssertTrue(app.staticTexts["home-error-message"].waitForExistence(timeout: 5))
    }

    private func restart(_ language: String) throws {
        var app = try launch("resume", language)
        try visible(app.buttons["home-next-action-button"], app)
        let label = app.buttons["home-latest-meeting-button"].label
        XCTAssertEqual(label, resumeLabel(language, pending: true))
        try click(app.buttons["home-next-action-button"], app)
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        app.terminate()
        // New app process, same fixed canonical seed; not a claim about persisted user data.
        app = try launch("resume", language); defer { app.terminate() }
        try visible(app.buttons["home-next-action-button"], app)
        XCTAssertEqual(app.buttons["home-latest-meeting-button"].label, label)
        try click(app.buttons["home-latest-meeting-button"], app)
        XCTAssertTrue(element("meeting-results-screen", app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Synthetic Resume Meeting")
    }

    func testEmptyKorean() throws { try empty("ko") }
    func testEmptyEnglish() throws { try empty("en") }
    func testPendingKorean() throws { try returning("pendingReview", "ko", pending: true) }
    func testPendingEnglish() throws { try returning("pendingReview", "en", pending: true) }
    func testAssignedKorean() throws { try returning("assignedWork", "ko", pending: false) }
    func testAssignedEnglish() throws { try returning("assignedWork", "en", pending: false) }
    func testNoProfileKorean() throws { try noProfile("ko") }
    func testNoProfileEnglish() throws { try noProfile("en") }
    func testLoadFailureKorean() throws { try failure("ko") }
    func testLoadFailureEnglish() throws { try failure("en") }
    func testRestartKorean() throws { try restart("ko") }
    func testRestartEnglish() throws { try restart("en") }
}
