import AppKit
import XCTest

@MainActor
final class AppShellUITests: XCTestCase {
    private static var invalidEnvironment = false
    private let projectID = "C8000000-0000-4000-8000-000000000001"
    private let meetingID = "C8000000-0000-4000-8000-000000000003"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.invalidEnvironment, "ENVIRONMENT_INVALID: no further UI attempts this run")
    }

    private func launch(seed: Bool = false, minimum: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = "ko"
        if seed { app.launchEnvironment["HAENA_UI_TESTING_MANUAL_BRIEF"] = "1" }
        if minimum { app.launchEnvironment["HAENA_UI_TEST_MINIMUM_WINDOW"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        addUIInterruptionMonitor(withDescription: "Shell isolation guard") { _ in
            MainActor.assumeIsolated { Self.invalidEnvironment = true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["shell-rail-home"].waitForExistence(timeout: 5))
        try guardEnvironment(app)
        return app
    }

    private func guardEnvironment(_ app: XCUIApplication) throws {
        let foreground = NSWorkspace.shared.frontmostApplication
        // XCTest's foreground state alone did not explain earlier clicks with an unchanged
        // target hierarchy. Also require the foreground process to be the HAE.NA executable,
        // never Chrome/Codex/a runner. No unrelated window contents are inspected.
        if Self.invalidEnvironment || app.state != .runningForeground
            || foreground?.executableURL?.lastPathComponent != "HAENA" {
            Self.invalidEnvironment = true
            throw XCTSkip("ENVIRONMENT_INVALID: foreground=\(foreground?.bundleIdentifier ?? "none"), target is not foreground")
        }
    }

    private func click(_ element: XCUIElement, in app: XCUIApplication) throws {
        try guardEnvironment(app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable, "Target must be reachable; do not fall back to blind coordinates")
        element.click()
        try guardEnvironment(app)
    }

    private func rail(_ destination: String, in app: XCUIApplication) throws {
        try click(app.buttons["shell-rail-\(destination)"], in: app)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testFiveRailDestinationsShowPurposefulEmptyStateAtMinimumWidth() throws {
        let app = try launch(minimum: true)
        defer { app.terminate() }
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, 722)
        let railFrame = element("shell-rail", in: app).frame
        for destination in ["review", "briefs", "transcripts", "projects"] {
            try rail(destination, in: app)
            let empty = element("shell-empty-\(destination)", in: app)
            XCTAssertTrue(empty.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(empty.frame.minX, railFrame.maxX)
            XCTAssertTrue(app.staticTexts["shell-selection-guidance"].exists)
            XCTAssertFalse(element("meeting-detail-screen", in: app).exists)
            XCTAssertEqual(app.sheets.count, 0)
        }
        try rail("home", in: app)
        XCTAssertTrue(app.staticTexts["product-name"].exists)
    }

    func testHomePendingReviewLinkAndSelectionSurviveRailNavigation() throws {
        let app = try launch(seed: true)
        defer { app.terminate() }
        try click(app.buttons["home-next-action-button"], in: app)
        XCTAssertTrue(element("work-state-review-screen", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        try rail("briefs", in: app)
        XCTAssertTrue(element("manual-continuity-brief-screen", in: app).waitForExistence(timeout: 5))
        try rail("transcripts", in: app)
        try click(app.buttons["meeting-row-\(meetingID)"], in: app)
        XCTAssertTrue(app.staticTexts["meeting-detail-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Continuity Review")
        XCTAssertTrue(element("meeting-transcript-pane", in: app).exists)
        for destination in ["home", "review", "projects", "transcripts"] {
            try rail(destination, in: app)
        }
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Continuity Review")
        XCTAssertFalse(element("shell-empty-transcripts", in: app).exists)
    }

    func testProjectSelectionAndMeetingResultsUseExistingViews() throws {
        let app = try launch(seed: true)
        defer { app.terminate() }
        try rail("projects", in: app)
        try click(app.buttons["project-row-\(projectID)"], in: app)
        XCTAssertTrue(element("project-detail-screen", in: app).waitForExistence(timeout: 5))
        let picker = element("project-detail-pane-picker", in: app)
        try click(picker.radioButtons["회의"], in: app)
        let row = element("meeting-row-\(meetingID)", in: app)
        try click(row, in: app)
        XCTAssertTrue(element("meeting-results-screen", in: app).waitForExistence(timeout: 5))
        try rail("home", in: app)
        try rail("projects", in: app)
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Continuity Review")
    }

    func testCaptureDismissalRoutesToSavedMeetingResults() throws {
        let app = try launch()
        defer { app.terminate() }
        try click(app.buttons["paste-transcript-button"], in: app)
        try click(app.buttons["new-project-button"], in: app)
        try click(app.textFields["new-project-name-field"], in: app)
        app.textFields["new-project-name-field"].typeText("Shell Synthetic Project")
        app.textFields["new-project-name-field"].typeKey(.return, modifierFlags: [])
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: app.textFields["new-project-name-field"])
        wait(for: [removed], timeout: 5)
        try click(app.textFields["meeting-title-field"], in: app)
        app.textFields["meeting-title-field"].typeText("Shell Synthetic Meeting")
        try click(app.textViews["transcript-text-editor"], in: app)
        app.textViews["transcript-text-editor"].typeText("Synthetic navigation-only transcript.")
        try click(app.buttons["save-text-meeting-button"], in: app)
        XCTAssertTrue(app.buttons["capture-open-results-button"].waitForExistence(timeout: 8))
        try click(app.buttons["capture-open-results-button"], in: app)
        XCTAssertTrue(element("meeting-results-screen", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Shell Synthetic Meeting")
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.buttons["shell-rail-home"].isHittable)
    }

    func testRailArrowFocusAndKeyboardActivationAtMinimumWidth() throws {
        let app = try launch(minimum: true)
        defer { app.terminate() }
        try rail("home", in: app)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        try guardEnvironment(app)
        XCTAssertTrue(element("shell-empty-review", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["shell-rail-review"].label, "검토")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(element("shell-empty-briefs", in: app).waitForExistence(timeout: 5))
    }
}
