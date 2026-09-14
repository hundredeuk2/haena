import XCTest

/// Task 2.8: one light core-loop tryout on an isolated synthetic account, driven the way the
/// product owner will use it — no guide, just what the screen offers next. The account is a fresh
/// directory under the system temporary directory (the Debug-only recovery-process contract),
/// seeded with the existing deterministic fixture: one pasted meeting, one proposed decision with a
/// stored quote. Everything persists in that directory and survives a relaunch; nothing touches
/// Application Support, audio, a provider or a model.
@MainActor
final class TryoutSmokeUITests: XCTestCase {
    private enum ID {
        static let project = "D0000000-0000-0000-0000-000000000100"
        static let segment = "D0000000-0000-0000-0000-000000000102"
        static let decision = "D0000000-0000-0000-0000-000000000002"
    }
    override func setUpWithError() throws { continueAfterFailure = false }

    private func element(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[name].firstMatch
    }
    private func text(_ identifier: String, _ app: XCUIApplication) -> String {
        let e = app.staticTexts[identifier]
        return (e.value as? String) ?? e.label
    }
    private func click(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5), item.identifier)
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable, item.identifier)
        item.click()
        try AppShellUITests.validateEnvironment(app)
    }
    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    /// The app treats the login session's per-user temporary directory (`NSTemporaryDirectory()`
    /// of a non-sandboxed process) as the only allowed home for an isolated account. The UI-test
    /// runner is sandboxed, so its own temporary directory is a container path the app refuses;
    /// the driver hands the app's directory in with `xcodebuild … TEST_RUNNER_HAENA_TRYOUT_TEMP=$TMPDIR`.
    private func accountBase() throws -> URL {
        guard let base = ProcessInfo.processInfo.environment["HAENA_TRYOUT_TEMP"], base.hasPrefix("/") else {
            throw XCTSkip("TRYOUT_UNCONFIGURED: pass TEST_RUNNER_HAENA_TRYOUT_TEMP=<per-user temp dir> to xcodebuild")
        }
        return URL(fileURLWithPath: base, isDirectory: true)
    }

    /// A clean synthetic account: a fresh, not-yet-existing root the app creates when it seeds.
    private func freshRoot() throws -> URL {
        try accountBase().appendingPathComponent("haena-028-tryout-\(UUID().uuidString)", isDirectory: true)
    }

    private func launch(_ language: String, root: URL, seed: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = language
        app.launchEnvironment["HAENA_UI_TEST_MINIMUM_WINDOW"] = "1"
        app.launchEnvironment["HAENA_RECOVERY_PROCESS_TESTING"] = "1"
        app.launchEnvironment["HAENA_RECOVERY_PROCESS_TEST_ROOT"] = root.path
        print("TRYOUT_ROOT root=\(root.path)")
        if seed { app.launchEnvironment["HAENA_RECOVERY_PROCESS_TEST_SEED"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["shell-rail-home"].waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        return app
    }

    /// fixture → evidence → approve one → quit → relaunch → next Brief.
    func testKoreanCoreLoopOnCleanAccountSurvivesRelaunch() throws {
        let root = try freshRoot()
        var app = try launch("ko", root: root, seed: true)
        // Step 1 — Home says what to do next without a guide.
        let next = app.buttons["home-next-action-button"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the next action must be visible on Home")
        snapshot("ko-1-home", app)
        try click(next, app)
        // Step 2 — Review shows the pending state as pending, with the stored quote as the way in.
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        XCTAssertEqual(text("pending-proposal-count", app), "AI 제안 1건")
        XCTAssertTrue(app.staticTexts["review-approval-boundary"].exists)
        XCTAssertEqual(text("proposal-card-\(ID.decision)-headline", app), "Synthetic decision awaiting review")
        let quote = app.buttons["proposal-evidence-\(ID.decision)"]
        XCTAssertEqual(quote.label, "원문 “Synthetic recovery evidence”")
        XCTAssertTrue(app.buttons["approve-proposal-\(ID.decision)"].isHittable)
        snapshot("ko-2-review-pending", app)
        // Step 3 — the quote opens the owning transcript at the exact segment.
        try click(quote, app)
        XCTAssertTrue(element("meeting-transcript-pane", app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transcript-segment-evidence-\(ID.segment)"].waitForExistence(timeout: 5))
        XCTAssertEqual(text("transcript-evidence-status", app), "검토 근거 발화를 강조 표시했습니다.")
        snapshot("ko-3-transcript-evidence", app)
        // Step 4 — approve exactly one candidate; the screen reports the change.
        try click(app.buttons["shell-rail-review"], app)
        try click(app.buttons["approve-proposal-\(ID.decision)"], app)
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "AI 제안 0건"), object: app.staticTexts["pending-proposal-count"])
        wait(for: [emptied], timeout: 5)
        XCTAssertTrue(app.staticTexts["no-pending-proposals"].exists)
        snapshot("ko-4-review-after-approval", app)
        // Step 5 — quit, relaunch on the same account (no seed), open the next Brief.
        app.terminate()
        app = try launch("ko", root: root, seed: false)
        XCTAssertFalse(app.buttons["home-next-action-button"].exists, "nothing is pending after approval")
        snapshot("ko-5-home-after-relaunch", app)
        try click(app.buttons["shell-rail-briefs"], app)
        try click(app.buttons["project-row-\(ID.project)"], app)
        XCTAssertTrue(element("manual-continuity-brief-screen", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("manual-continuity-brief-scroll", app).waitForExistence(timeout: 5))
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), "판정 대기 0건 · 확정 아젠다 0건")
        XCTAssertTrue(element("manual-brief-confirmed-decisions", app).staticTexts.matching(
            NSPredicate(format: "value == %@", "Synthetic decision awaiting review")).firstMatch.exists,
            "the approved decision is carried state after relaunch")
        XCTAssertEqual(text("manual-continuity-brief-candidate-state", app), "첫 브리프입니다. 비교할 이전 회의 상태가 없어 판정할 후보가 없습니다.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).count, 0)
        XCTAssertFalse(element("manual-continuity-brief-error", app).exists)
        snapshot("ko-6-brief-after-relaunch", app)
        app.terminate()
    }

    /// The same screens in English: copy, CTAs and navigation only.
    func testEnglishSmokeOfTheSameScreens() throws {
        let root = try freshRoot()
        let app = try launch("en", root: root, seed: true)
        defer { app.terminate() }
        let next = app.buttons["home-next-action-button"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        snapshot("en-1-home", app)
        try click(next, app)
        XCTAssertTrue(element("work-state-review-screen", app).waitForExistence(timeout: 5))
        XCTAssertEqual(text("pending-proposal-count", app), "AI Suggestions: 1")
        let quote = app.buttons["proposal-evidence-\(ID.decision)"]
        XCTAssertEqual(quote.label, "Evidence “Synthetic recovery evidence”")
        XCTAssertEqual(app.buttons["approve-proposal-\(ID.decision)"].label, "Approve")
        XCTAssertEqual(app.buttons["exclude-proposal-\(ID.decision)"].label, "Exclude")
        snapshot("en-2-review", app)
        try click(quote, app)
        XCTAssertTrue(element("meeting-transcript-pane", app).waitForExistence(timeout: 5))
        XCTAssertEqual(text("transcript-evidence-status", app), "The review evidence segment is highlighted.")
        XCTAssertEqual(text("transcript-segment-evidence-\(ID.segment)", app), "Evidence segment")
        snapshot("en-3-transcript", app)
        try click(app.buttons["shell-rail-briefs"], app)
        XCTAssertTrue(element("manual-continuity-brief-screen", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("manual-continuity-brief-scroll", app).waitForExistence(timeout: 5))
        XCTAssertEqual(text("manual-continuity-brief-header-summary", app), "Awaiting verdict: 1 · Approved agenda items: 0")
        XCTAssertTrue(app.staticTexts["manual-continuity-brief-boundary"].exists)
        let adopt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manual-brief-approve-")).firstMatch
        XCTAssertTrue(adopt.waitForExistence(timeout: 5))
        XCTAssertEqual(adopt.label, "Approve New Item")
        XCTAssertTrue(element("manual-continuity-brief-agenda-section", app).exists)
        snapshot("en-4-brief", app)
        try click(app.buttons["shell-rail-home"], app)
        XCTAssertTrue(next.waitForExistence(timeout: 5), "still pending: nothing was approved in the English smoke")
    }
}
