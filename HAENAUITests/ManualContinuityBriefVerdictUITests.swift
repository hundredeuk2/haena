import CryptoKit
import XCTest

/// Task 2.7: A (already approved), B (awaiting a verdict), C (approved next agenda) are visibly
/// separate; each candidate's primary action names its real effect; a verdict changes one
/// candidate; failure keeps it. Synthetic seed only, guarded launch, minimum window.
@MainActor
final class ManualContinuityBriefVerdictUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func id(_ n: Int) -> String { String(format: "C8000000-0000-4000-8000-%012d", n) }
    private func element(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[name].firstMatch
    }
    private func click(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        try reveal(item, app)
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable, item.identifier)
        item.click()
        try AppShellUITests.validateEnvironment(app)
    }
    private func reveal(_ item: XCUIElement, _ app: XCUIApplication) throws {
        let scroll = app.scrollViews.matching(NSPredicate(format: "identifier == %@", "manual-continuity-brief-screen")).firstMatch
        guard scroll.exists else { return }
        for _ in 0..<30 {
            if item.exists && item.isHittable && scroll.frame.contains(item.frame) { return }
            try AppShellUITests.validateEnvironment(app)
            let delta = item.exists && item.frame.midY < scroll.frame.midY ? 200.0 : -200.0
            scroll.scroll(byDeltaX: 0, deltaY: delta)
        }
    }
    private func launch(_ language: String, scenario: String = "full") throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TESTING_MANUAL_BRIEF"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_MANUAL_BRIEF_SCENARIO"] = scenario
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = language
        app.launchEnvironment["HAENA_UI_TEST_MINIMUM_WINDOW"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["shell-rail-home"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        try click(app.buttons["shell-rail-briefs"], app)
        try click(app.buttons["project-row-\(id(1))"], app)
        XCTAssertTrue(element("manual-continuity-brief-screen", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("manual-continuity-brief-scroll", app).waitForExistence(timeout: 5))
        return app
    }
    private func text(_ identifier: String, _ app: XCUIApplication) -> String {
        let e = app.staticTexts[identifier]
        return (e.value as? String) ?? e.label
    }
    private var completionProposal: String { "manual-brief-approve-" + proposalID(previous: 201, current: 202, kind: "action_item", transition: "completed") }
    /// The seed's deterministic proposal id, derived exactly as the product does.
    private func proposalID(previous: Int, current: Int?, kind: String, transition: String) -> String {
        let key = ["haena.work-state-transition.v1", id(1).lowercased(), kind, transition,
                   id(previous).lowercased(), current.map { id($0).lowercased() } ?? "none"].joined(separator: "|")
        return DeterministicID.uuid(for: key)
    }

    private func sections(_ language: String) throws {
        let app = try launch(language); defer { app.terminate() }
        let ko = language == "ko"
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), ko ? "판정 대기 8건 · 확정 아젠다 1건" : "Awaiting verdict: 8 · Approved agenda items: 1")
        XCTAssertTrue(app.staticTexts["manual-continuity-brief-boundary"].exists)
        // A, B, C exist and are ordered top to bottom.
        let a = element("manual-continuity-brief-confirmed-section", app)
        let b = element("manual-continuity-brief-candidates-section", app)
        let c = element("manual-continuity-brief-agenda-section", app)
        XCTAssertTrue(a.exists); XCTAssertTrue(b.exists); XCTAssertTrue(c.exists)
        XCTAssertLessThan(a.frame.minY, b.frame.minY); XCTAssertLessThan(b.frame.minY, c.frame.minY)
        // A and C carry no verdict buttons; B carries all of them.
        XCTAssertEqual(a.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).count, 0)
        XCTAssertEqual(c.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).count, 0)
        XCTAssertEqual(c.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-reject-")).count, 0)
        XCTAssertTrue(c.descendants(matching: .any)["manual-brief-agenda-\(id(401))"].exists)
        XCTAssertFalse(c.descendants(matching: .any)["manual-brief-agenda-\(id(400))"].exists, "the candidate never sits in C")
        XCTAssertTrue(b.descendants(matching: .any)["manual-brief-agenda-\(id(400))"].exists)
        XCTAssertTrue(b.buttons["manual-brief-approve-\(id(400))"].exists)
        XCTAssertFalse(app.staticTexts["manual-continuity-brief-candidate-state"].exists)
        XCTAssertTrue(element("manual-brief-confirmed-mine", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch.exists, "before any verdict the prior is active work")
        XCTAssertFalse(element("manual-brief-confirmed-completed", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch.exists)
        // Distinct verdict labels: completion vs blocked vs deferred vs overdue.
        let completion = app.buttons[completionProposal]
        XCTAssertTrue(completion.exists)
        XCTAssertEqual(completion.label, ko ? "완료로 반영" : "Mark Completed")
        let blocked = app.buttons["manual-brief-approve-" + proposalID(previous: 203, current: 204, kind: "action_item", transition: "delayed")]
        let deferred = app.buttons["manual-brief-approve-" + proposalID(previous: 205, current: 206, kind: "action_item", transition: "delayed")]
        let overdue = app.buttons["manual-brief-approve-" + proposalID(previous: 207, current: nil, kind: "action_item", transition: "delayed")]
        XCTAssertEqual(blocked.label, ko ? "차단 확인 · 상태 유지" : "Acknowledge Block · Keeps Status")
        XCTAssertEqual(deferred.label, ko ? "지연 확인 · 상태 유지" : "Acknowledge Delay · Keeps Status")
        XCTAssertEqual(overdue.label, ko ? "기한 초과 확인 · 기한 유지" : "Acknowledge Overdue · Keeps Due Date")
        XCTAssertTrue(app.staticTexts["manual-brief-delay-blocked"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "-candidate-")).firstMatch.exists)
        XCTAssertFalse(app.buttons["manual-brief-approve-all"].exists)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "brief-verdict-accessibility-" + language; hierarchy.lifetime = .keepAlways; add(hierarchy)
        // One verdict → that candidate leaves B, the prior item appears in A as completed, count drops.
        let effect = "manual-brief-effect-" + proposalID(previous: 201, current: 202, kind: "action_item", transition: "completed")
        XCTAssertEqual(text(effect, app), ko ? "승인 시 · 기존 항목을 완료로 표시합니다." : "On approval · Marks the existing item completed.")
        try click(completion, app)
        XCTAssertTrue(waitUntilGone(app.buttons[completionProposal]))
        XCTAssertEqual(text("manual-continuity-brief-feedback", app), ko ? "변화를 승인하고 반영했습니다." : "Change approved and applied.")
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), ko ? "판정 대기 7건 · 확정 아젠다 1건" : "Awaiting verdict: 7 · Approved agenda items: 1")
        XCTAssertTrue(blocked.exists); XCTAssertTrue(deferred.exists); XCTAssertTrue(overdue.exists)
        let completedTitle = element("manual-brief-confirmed-completed", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch
        XCTAssertTrue(completedTitle.waitForExistence(timeout: 5), "the completed prior now sits in A's completed group")
        XCTAssertFalse(element("manual-brief-confirmed-mine", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch.exists)
        // Reject one progress note: it leaves B and nothing in A changes.
        let rejectDeferred = app.buttons["manual-brief-reject-" + proposalID(previous: 205, current: 206, kind: "action_item", transition: "delayed")]
        XCTAssertEqual(rejectDeferred.label, ko ? "진행 후보 거절" : "Reject Progress Note")
        try click(rejectDeferred, app)
        XCTAssertTrue(waitUntilGone(rejectDeferred))
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), ko ? "판정 대기 6건 · 확정 아젠다 1건" : "Awaiting verdict: 6 · Approved agenda items: 1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "brief-verdict-" + language; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testSectionsAndVerdictsKorean() throws { try sections("ko") }
    func testSectionsAndVerdictsEnglish() throws { try sections("en") }

    func testApplyFailureKeepsCandidateAndOffersRetry() throws {
        let app = try launch("en", scenario: "applyFailure"); defer { app.terminate() }
        let completion = app.buttons[completionProposal]
        try click(completion, app)
        let feedback = app.staticTexts["manual-continuity-brief-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(text("manual-continuity-brief-feedback", app),
                       "This request cannot be processed with the current saved state. The candidate is still here. You can try again.")
        XCTAssertTrue(completion.exists); XCTAssertTrue(completion.isEnabled)
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), "Awaiting verdict: 8 · Approved agenda items: 1")
        XCTAssertFalse(element("manual-brief-confirmed-completed", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch.exists, "nothing moved to A")
        XCTAssertTrue(element("manual-brief-confirmed-mine", app).staticTexts.matching(NSPredicate(format: "value == %@", "Export transition fixture")).firstMatch.exists)
    }

    func testFirstBriefIsHonestlyEmpty() throws {
        let app = try launch("ko", scenario: "firstBrief"); defer { app.terminate() }
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), "판정 대기 0건 · 확정 아젠다 1건")
        XCTAssertEqual(text("manual-continuity-brief-candidate-state", app), "첫 브리프입니다. 비교할 이전 회의 상태가 없어 판정할 후보가 없습니다.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).count, 0)
        XCTAssertFalse(element("manual-continuity-brief-error", app).exists)
        XCTAssertFalse(element("manual-continuity-brief-transition-unavailable", app).exists)
        XCTAssertTrue(element("manual-continuity-brief-confirmed-section", app).exists)
    }

    func testZeroCandidatesIsDistinctFromFirstBriefAndFailure() throws {
        let app = try launch("en", scenario: "zeroCandidates"); defer { app.terminate() }
        XCTAssertEqual(text("manual-continuity-brief-candidate-state", app), "Nothing awaits a verdict. The earlier meeting state carries forward unchanged.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).count, 0)
        XCTAssertFalse(element("manual-continuity-brief-error", app).exists)
        XCTAssertTrue(element("manual-continuity-brief-agenda-section", app).descendants(matching: .any)["manual-brief-agenda-\(id(401))"].exists)
    }

    func testKeyboardSpaceAppliesTheFocusedVerdictOnly() throws {
        let app = try launch("en"); defer { app.terminate() }
        let completion = app.buttons[completionProposal]
        try reveal(completion, app)
        func isExactlyFocused() -> Bool {
            let attributes = completion.debugDescription.components(separatedBy: "\n").first { $0.hasPrefix("Attributes:") } ?? ""
            return attributes.contains("Keyboard Focused")
        }
        for _ in 0..<40 {
            if isExactlyFocused() { break }
            try AppShellUITests.validateEnvironment(app)
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(isExactlyFocused())
        app.typeKey(.space, modifierFlags: [])
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(waitUntilGone(app.buttons[completionProposal]))
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), "Awaiting verdict: 7 · Approved agenda items: 1")
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: timeout) == .completed
    }
}

/// Mirrors `WorkStateTransitionProposal.deterministicID(forDedupKey:)` so the test can address the
/// seed's proposals by their stored id without importing the app module.
private enum DeterministicID {
    static func uuid(for key: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}
