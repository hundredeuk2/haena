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

    private func launch(seed: Bool = false, minimum: Bool = false, capturePrefill: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = "ko"
        if capturePrefill { app.launchEnvironment["HAENA_UI_TEST_CAPTURE_PREFILL"] = "1" }
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
        try Self.validateEnvironment(app)
    }

    /// The selected legacy non-input regressions use the same isolation/stop guard.
    static func guardedLaunch(for test: XCTestCase, language: String = "ko",
                              homeScenario: String? = nil, minimum: Bool = false,
                              captureScenario: String? = nil, reviewScenario: String? = nil) throws -> XCUIApplication {
        try XCTSkipIf(invalidEnvironment, "ENVIRONMENT_INVALID: no further UI attempts this run")
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = language
        if let homeScenario { app.launchEnvironment["HAENA_UI_TEST_HOME"] = homeScenario }
        if let captureScenario { app.launchEnvironment["HAENA_UI_TEST_CAPTURE_LIFECYCLE"] = captureScenario }
        if let reviewScenario { app.launchEnvironment["HAENA_UI_TEST_REVIEW_QUEUE"] = reviewScenario }
        if minimum { app.launchEnvironment["HAENA_UI_TEST_MINIMUM_WINDOW"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        test.addUIInterruptionMonitor(withDescription: "Shell regression isolation guard") { _ in
            MainActor.assumeIsolated { invalidEnvironment = true }
            return false
        }
        app.launch()
        try validateEnvironment(app)
        return app
    }

    static func validateEnvironment(_ app: XCUIApplication) throws {
        let foreground = NSWorkspace.shared.frontmostApplication
        // XCTest's foreground state alone did not explain earlier clicks with an unchanged
        // target hierarchy. Also require the foreground process to be the HAE.NA executable,
        // never Chrome/Codex/a runner. No unrelated window contents are inspected.
        if Self.invalidEnvironment || app.state != .runningForeground
            || foreground?.executableURL?.lastPathComponent != "HAENA" {
            Self.invalidEnvironment = true
            throw XCTSkip("ENVIRONMENT_INVALID: foreground=\(foreground?.bundleIdentifier ?? "none"), target is not foreground")
        }
        // WindowServer order/bounds only: never read another application's title or contents.
        // Foreground is necessary but not sufficient if a different window covers the target.
        let targetFrame = app.windows.firstMatch.frame
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            Self.invalidEnvironment = true
            throw XCTSkip("ENVIRONMENT_INVALID: window order unavailable")
        }
        var foundTarget = false
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if pid == foreground?.processIdentifier { foundTarget = true; break }
            if frame.intersects(targetFrame) {
                Self.invalidEnvironment = true
                let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
                throw XCTSkip("ENVIRONMENT_INVALID: overlapping foreground window owner=\(owner) frame=\(frame)")
            }
        }
        if !foundTarget {
            Self.invalidEnvironment = true
            throw XCTSkip("ENVIRONMENT_INVALID: target window missing from WindowServer")
        }
    }

    private func click(_ element: XCUIElement, in app: XCUIApplication) throws {
        try guardEnvironment(app)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let identifier = element.identifier
        print("SHELL_OBSERVATION target=\(identifier) frame=\(element.frame) enabled=\(element.isEnabled) hittable=\(element.isHittable) foreground=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") window=\(app.windows.firstMatch.frame)")
        attachTargetWindow(app, name: "before-\(identifier)")
        XCTAssertTrue(element.isHittable, "Target must be reachable; do not fall back to blind coordinates")
        element.click()
        try guardEnvironment(app)
        // Saving/dismissing legitimately removes the clicked element. Attachment naming must
        // not re-query that obsolete element after the action has completed.
        attachTargetWindow(app, name: "after-\(identifier)")
    }

    private func attachTargetWindow(_ app: XCUIApplication, name: String) {
        // A synthetic app window only, excluding the application menu and whole desktop.
        let attachment = XCTAttachment(string: app.windows.firstMatch.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        let app = try launch(capturePrefill: true)
        defer { app.terminate() }
        try click(app.buttons["paste-transcript-button"], in: app)
        let picker = element("project-picker", in: app)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Shell Synthetic Project"), object: picker
        )
        wait(for: [selected], timeout: 5)
        try guardEnvironment(app)
        XCTAssertEqual(picker.value as? String, "Shell Synthetic Project")
        XCTAssertEqual(app.textFields["meeting-title-field"].value as? String, "Shell Synthetic Meeting")
        XCTAssertEqual(app.textViews["transcript-text-editor"].value as? String, "Synthetic navigation-only transcript.")
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
        try guardEnvironment(app)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        try guardEnvironment(app)
        XCTAssertTrue(element("shell-empty-briefs", in: app).waitForExistence(timeout: 5))
    }
}
