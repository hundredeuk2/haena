import XCTest

/// Task 2.6: the source quote on a Review card opens the owning meeting's transcript at the exact
/// stored segment. Synthetic seed only; the guarded launch skips on any foreground interference.
@MainActor
final class ReviewEvidenceUITests: XCTestCase {
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
    /// The review list scrolls inside the minimum window; a card below the fold exists but is not
    /// hittable until it is scrolled into the list's own viewport (same as the 2.5 ownership case).
    private func reveal(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        let list = element("work-state-review-screen", app).scrollViews.firstMatch
        for _ in 0..<8 {
            if item.isHittable && list.frame.contains(item.frame) { break }
            try AppShellUITests.validateEnvironment(app)
            list.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(list.frame.contains(item.frame), "Scroll the whole quote into its viewport before clicking")
    }
    private func launch(_ language: String, scenario: String = "evidence") throws -> XCUIApplication {
        let app = try AppShellUITests.guardedLaunch(for: self, language: language, minimum: true, reviewScenario: scenario)
        try click(app.buttons["home-next-action-button"], app)
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
    private func quote(_ language: String, _ timestamp: String?, _ text: String) -> String {
        let prefix = language == "ko" ? "원문" : "Evidence"
        return timestamp.map { "\(prefix) \($0) “\(text)”" } ?? "\(prefix) “\(text)”"
    }
    /// The transcript pane of `title` is showing with exactly `segment` marked as the evidence.
    private func assertTranscript(_ app: XCUIApplication, title: String, segment: Int, notMarked: [Int], language: String) {
        XCTAssertTrue(element("meeting-transcript-pane", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("work-state-review-screen", app).exists)
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, title)
        XCTAssertTrue(app.staticTexts["transcript-evidence-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["transcript-evidence-status"].value as? String,
                       language == "ko" ? "검토 근거 발화를 강조 표시했습니다." : "The review evidence segment is highlighted.")
        XCTAssertFalse(app.staticTexts["transcript-evidence-unavailable"].exists)
        let marker = app.staticTexts["transcript-segment-evidence-\(id(segment))"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.value as? String, language == "ko" ? "근거 발화" : "Evidence segment")
        XCTAssertTrue(element("transcript-segment-\(id(segment))", app).exists)
        for other in notMarked {
            XCTAssertFalse(app.staticTexts["transcript-segment-evidence-\(id(other))"].exists, "segment \(other) must not be marked")
        }
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-segment-evidence-")).count, 1)
    }

    private func navigation(_ language: String) throws {
        let app = try launch(language); defer { app.terminate() }
        count(5, language, app)
        // Decision 100 → segment 4. Segment 8 carries identical text and must stay unmarked.
        try filter(language == "ko" ? "결정" : "Decisions", app)
        let decisionQuote = app.buttons["proposal-evidence-\(id(100))"]
        XCTAssertTrue(decisionQuote.waitForExistence(timeout: 5))
        XCTAssertEqual(decisionQuote.identifier, "proposal-evidence-\(id(100))")
        XCTAssertEqual(decisionQuote.label, quote(language, "01:05", "Synthetic exact source quote."))
        XCTAssertLessThan(decisionQuote.frame.minY, app.buttons["approve-proposal-\(id(100))"].frame.minY)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "review-evidence-accessibility-" + language
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try click(decisionQuote, app)
        assertTranscript(app, title: "Synthetic Review Meeting", segment: 4, notMarked: [8, 7], language: language)
        XCTAssertFalse(element("meeting-audio-player", app).exists, "no stored audio: no player, no invented position")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "transcript-evidence-highlight-" + language
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Back in Review the same proposal is still pending, identical, and still approvable.
        try click(app.buttons["shell-rail-review"], app)
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        count(5, language, app)
        try filter(language == "ko" ? "결정" : "Decisions", app)
        XCTAssertTrue(element("proposal-card-\(id(100))", app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(100))-headline"].value as? String, "Synthetic pending decision")
        XCTAssertTrue(app.buttons["approve-proposal-\(id(100))"].isHittable)
        XCTAssertTrue(app.buttons["exclude-proposal-\(id(100))"].isHittable)
        XCTAssertFalse(app.buttons["approve-proposal-\(id(100))"].isSelected)
        // Agenda 103 → segment 7 of the same meeting: the selection changes, segment 4 is unmarked.
        try filter(language == "ko" ? "아젠다" : "Agenda", app)
        let agendaQuote = app.buttons["proposal-evidence-\(id(103))"]
        XCTAssertEqual(agendaQuote.label, quote(language, "02:05", "Synthetic second source quote."))
        try click(agendaQuote, app)
        assertTranscript(app, title: "Synthetic Review Meeting", segment: 7, notMarked: [4, 8], language: language)
        // Action 104 → the pasted meeting: exact segment, no timestamp, no audio.
        try click(app.buttons["shell-rail-review"], app)
        count(5, language, app)
        try filter(language == "ko" ? "업무" : "Actions", app)
        let pastedQuote = app.buttons["proposal-evidence-\(id(104))"]
        try reveal(pastedQuote, app)
        XCTAssertEqual(pastedQuote.label, quote(language, nil, "Synthetic other source."))
        try click(pastedQuote, app)
        assertTranscript(app, title: "Synthetic Earlier Meeting", segment: 5, notMarked: [4, 7, 8], language: language)
        XCTAssertFalse(element("meeting-audio-player", app).exists)
        XCTAssertEqual(app.staticTexts["meeting-detail-source-type"].value as? String,
                       language == "ko" ? "텍스트 입력" : "Pasted Text")
        // Rail navigation clears the one-shot highlight but keeps the meeting; nothing was approved.
        try click(app.buttons["shell-rail-review"], app)
        count(5, language, app)
        try click(app.buttons["shell-rail-transcripts"], app)
        XCTAssertTrue(element("meeting-transcript-pane", app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Synthetic Earlier Meeting")
        XCTAssertFalse(app.staticTexts["transcript-evidence-status"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-segment-evidence-")).count, 0)
        try click(app.buttons["shell-rail-review"], app)
        count(5, language, app)
    }

    func testEvidenceNavigationKorean() throws { try navigation("ko") }
    func testEvidenceNavigationEnglish() throws { try navigation("en") }

    func testKeyboardActivationOpensExactSegment() throws {
        let app = try launch("en"); defer { app.terminate() }
        try filter("Decisions", app)
        let quoteButton = app.buttons["proposal-evidence-\(id(100))"]
        XCTAssertTrue(quoteButton.waitForExistence(timeout: 5))
        func isExactlyFocused() -> Bool {
            let attributes = quoteButton.debugDescription.components(separatedBy: "\n").first { $0.hasPrefix("Attributes:") } ?? ""
            print("EVIDENCE_FOCUS_ATTRIBUTES \(attributes)")
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
        assertTranscript(app, title: "Synthetic Review Meeting", segment: 4, notMarked: [8, 7], language: "en")
        try click(app.buttons["shell-rail-review"], app)
        count(5, "en", app)
        XCTAssertTrue(element("proposal-card-\(id(100))", app).waitForExistence(timeout: 5))
    }

    func testMissingSourceKeepsQuoteWithoutLink() throws {
        let app = try launch("en", scenario: "missingSource"); defer { app.terminate() }
        try filter("Decisions", app)
        XCTAssertFalse(app.buttons["proposal-evidence-\(id(100))"].exists)
        XCTAssertEqual(app.staticTexts["proposal-evidence-\(id(100))"].value as? String, "Evidence “Synthetic exact source quote.”")
        XCTAssertEqual(app.staticTexts["proposal-card-\(id(100))-source-issue"].value as? String,
                       "The quote is preserved, but the source segment could not be found.")
        XCTAssertTrue(app.buttons["approve-proposal-\(id(100))"].isHittable)
        XCTAssertFalse(element("meeting-transcript-pane", app).exists)
        count(5, "en", app)
    }
}
