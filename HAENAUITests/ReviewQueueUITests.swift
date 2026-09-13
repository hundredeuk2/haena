import XCTest

@MainActor
final class ReviewQueueUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func id(_ n: Int) -> String { String(format: "CC000000-0000-4000-8000-%012d", n) }
    private func element(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[name].firstMatch
    }
    private func click(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable)
        item.click()
        try AppShellUITests.validateEnvironment(app)
    }
    private func launch(_ language: String, scenario: String = "queue") throws -> XCUIApplication {
        let app = try AppShellUITests.guardedLaunch(for: self, language: language, minimum: true, reviewScenario: scenario)
        if scenario == "empty" {
            try click(app.buttons["shell-rail-review"], app)
            try click(app.buttons["project-row-\(id(1))"], app)
        } else { try click(app.buttons["home-next-action-button"], app) }
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        return app
    }
    private func filter(_ label: String, _ app: XCUIApplication) throws {
        try click(element("review-filter-picker", app).radioButtons[label], app)
    }
    private func count(_ expected: Int, _ language: String, _ app: XCUIApplication) {
        let label = language == "ko" ? "AI 제안 \(expected)건" : "AI Suggestions: \(expected)"
        let predicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", label), object: app.staticTexts["pending-proposal-count"])
        wait(for: [predicate], timeout: 5)
    }
    private func presentation(_ language: String) throws {
        let app = try launch(language); defer { app.terminate() }
        count(5, language, app)
        XCTAssertTrue(app.staticTexts["review-approval-boundary"].exists)
        XCTAssertFalse(element("approved-work-state-screen", app).exists)
        XCTAssertFalse(element("active-action-item-\(id(201))", app).exists)
        let labels = language == "ko" ? ["전체", "결정", "업무", "질문", "아젠다"] : ["All", "Decisions", "Actions", "Questions", "Agenda"]
        for (index, label) in labels.enumerated() {
            try filter(label, app)
            count(5, language, app)
            let expected = [5, 1, 2, 1, 1][index]
            XCTAssertEqual(app.staticTexts["review-visible-count"].value as? String,
                language == "ko" ? "표시 \(expected) / 미검토 전체 5" : "Showing \(expected) / Total pending 5")
        }
        for (label, n) in zip(Array(labels.dropFirst()), [100, 101, 102, 103]) {
            try filter(label, app)
            XCTAssertTrue(app.staticTexts["proposal-card-\(id(n))-kind"].exists)
            XCTAssertTrue(app.staticTexts["proposal-confidence-\(id(n))"].exists)
            XCTAssertTrue(app.staticTexts["proposal-card-\(id(n))-headline"].exists)
            XCTAssertEqual(app.staticTexts["proposal-evidence-\(id(n))"].value as? String,
                language == "ko" ? "원문 01:05 “Synthetic exact source quote.”" : "Evidence 01:05 “Synthetic exact source quote.”")
            XCTAssertEqual(app.buttons["edit-action-item-\(id(n))"].exists, n == 101)
            let approve = app.buttons["approve-proposal-\(id(n))"]
            let exclude = app.buttons["exclude-proposal-\(id(n))"]
            XCTAssertTrue(approve.isHittable); XCTAssertTrue(exclude.isHittable)
            XCTAssertLessThan(approve.frame.minX, exclude.frame.minX)
            XCTAssertFalse(approve.isSelected)
        }
        try filter(labels[2], app)
        let meta = element("proposal-card-\(id(101))-metadata", app)
        XCTAssertTrue(meta.exists)
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(101))-assignee"].value as? String,
                       language == "ko" ? "담당 Synthetic Reviewer" : "Assignee Synthetic Reviewer")
        let date = DateFormatter()
        date.locale = Locale(identifier: language); date.dateStyle = .medium; date.timeStyle = .none
        let due = date.string(from: Date(timeIntervalSince1970: 1_786_358_400))
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(101))-due"].value as? String,
                       language == "ko" ? "마감 \(due)" : "Due \(due)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "review-presentation-" + language
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "review-accessibility-" + language
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        count(5, language, app) // navigating/filtering did not approve anything
    }
    private func verdictAndEdit(_ language: String) throws {
        let app = try launch(language); defer { app.terminate() }
        try filter(language == "ko" ? "결정" : "Decisions", app)
        try click(app.buttons["approve-proposal-\(id(100))"], app)
        count(4, language, app)
        XCTAssertFalse(element("proposal-card-\(id(100))", app).exists)
        try filter(language == "ko" ? "질문" : "Questions", app)
        try click(app.buttons["exclude-proposal-\(id(102))"], app)
        count(3, language, app)
        XCTAssertFalse(element("proposal-card-\(id(102))", app).exists)
        try filter(language == "ko" ? "업무" : "Actions", app)
        try click(app.buttons["edit-action-item-\(id(101))"], app)
        XCTAssertEqual(app.staticTexts["edit-action-item-title"].value as? String, "Synthetic pending action")
        let picker = element("action-item-assignee-picker", app)
        try click(picker, app)
        try click(app.menuItems[language == "ko" ? "미지정" : "Unassigned"], app)
        try click(app.checkBoxes["action-item-due-date-toggle"], app)
        try click(app.buttons["save-action-item-button"], app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-action-item-button"])
        wait(for: [dismissed], timeout: 5)
        XCTAssertEqual(app.sheets.count, 0)
        count(3, language, app)
        XCTAssertTrue(element("proposal-card-\(id(101))", app).exists)
        XCTAssertTrue(element("proposal-card-\(id(104))", app).exists)
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(101))-assignee"].value as? String,
                       language == "ko" ? "담당자 미지정" : "Assignee Not Set")
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(101))-due"].value as? String,
                       language == "ko" ? "마감일 미지정" : "No due date assigned")
        try click(app.buttons["shell-rail-home"], app)
        XCTAssertTrue(app.buttons["home-latest-meeting-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-latest-meeting-button"].label.contains(language == "ko" ? "미검토 제안: 2" : "Unreviewed proposals in this meeting: 2"))
        try click(app.buttons["home-next-action-button"], app)
        count(3, language, app)
    }
    private func ownership(_ language: String) throws {
        let app = try launch(language); defer { app.terminate() }
        for (kind, n, title) in [("decision", 200, "Synthetic approved decision"), ("actionItem", 201, "Synthetic approved action"),
                                ("openQuestion", 202, "Synthetic approved question"), ("agendaItem", 203, "Synthetic approved agenda")] {
            try click(app.buttons["shell-rail-projects"], app)
            let target = app.buttons["status-open-\(kind)-\(id(n))"]
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            for _ in 0..<8 {
                if target.isHittable && app.scrollViews.firstMatch.frame.contains(target.frame) { break }
                try AppShellUITests.validateEnvironment(app)
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
            }
            XCTAssertTrue(app.scrollViews.firstMatch.frame.contains(target.frame), "Scroll the whole row into its viewport before clicking")
            try click(target, app)
            XCTAssertTrue(element("approved-work-state-screen", app).waitForExistence(timeout: 5))
            XCTAssertFalse(element("work-state-review-screen", app).exists)
            XCTAssertEqual(app.staticTexts["approved-selected-object"].value as? String,
                           language == "ko" ? "선택한 승인 항목: \(title)" : "Selected approved item: \(title)")
            XCTAssertFalse(app.buttons["approve-proposal-\(id(100))"].exists)
            try click(app.buttons["shell-rail-review"], app)
            count(5, language, app)
        }
    }
    private func empty(_ language: String) throws {
        let app = try launch(language, scenario: "empty"); defer { app.terminate() }
        count(0, language, app)
        XCTAssertTrue(app.staticTexts["no-pending-proposals"].exists)
        XCTAssertFalse(element("active-action-item-\(id(201))", app).exists)
    }
    func testPresentationKorean() throws { try presentation("ko") }
    func testPresentationEnglish() throws { try presentation("en") }
    func testVerdictEditKorean() throws { try verdictAndEdit("ko") }
    func testVerdictEditEnglish() throws { try verdictAndEdit("en") }
    func testOwnershipKorean() throws { try ownership("ko") }
    func testOwnershipEnglish() throws { try ownership("en") }
    func testEmptyKorean() throws { try empty("ko") }
    func testEmptyEnglish() throws { try empty("en") }
    func testMissingSourceIsHonest() throws {
        let app = try launch("en", scenario: "missingSource"); defer { app.terminate() }
        try filter("Decisions", app)
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(100))-source-issue"].value as? String,
                       "The quote is preserved, but the source segment could not be found.")
        XCTAssertEqual(app.staticTexts["proposal-evidence-\(id(100))"].value as? String, "Evidence “Synthetic exact source quote.”")
        count(5, "en", app)
    }
    func testFocusedKeyboardApprovalOnly() throws {
        let app = try launch("en"); defer { app.terminate() }
        try filter("Decisions", app)
        let approve = app.buttons["approve-proposal-\(id(100))"]
        func isExactlyFocused() -> Bool {
            // The full debugDescription also includes ancestor attributes. Only this button's
            // own Attributes line can prove focus; a focused ancestor is not explicit approval.
            let attributes = approve.debugDescription.components(separatedBy: "\n").first { $0.hasPrefix("Attributes:") } ?? ""
            print("REVIEW_FOCUS_ATTRIBUTES \(attributes)")
            return attributes.contains("Keyboard Focused")
        }
        for _ in 0..<24 {
            if isExactlyFocused() { break }
            try AppShellUITests.validateEnvironment(app)
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(isExactlyFocused())
        count(5, "en", app)
        app.typeKey(.space, modifierFlags: [])
        try AppShellUITests.validateEnvironment(app)
        count(4, "en", app)
        XCTAssertFalse(element("proposal-card-\(id(100))", app).exists)
    }
}
