import XCTest

@MainActor
final class CaptureLifecycleUITests: XCTestCase {
    private enum Path { case paste, audio, record }
    override func setUpWithError() throws { continueAfterFailure = false }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    private func click(_ item: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        try AppShellUITests.validateEnvironment(app)
        XCTAssertTrue(item.isHittable)
        item.click()
        try AppShellUITests.validateEnvironment(app)
    }
    private func launch(_ scenario: String, language: String = "ko") throws -> XCUIApplication {
        try AppShellUITests.guardedLaunch(for: self, language: language, captureScenario: scenario)
    }
    private func open(_ path: Path, _ app: XCUIApplication) throws {
        try click(app.buttons[path == .paste ? "paste-transcript-button" : path == .audio ? "import-button" : "record-button"], app)
        XCTAssertTrue(element("capture-phase-ready", app).waitForExistence(timeout: 5))
        if path == .record {
            try click(app.buttons["start-recording-button"], app)
            XCTAssertTrue(element("recording-indicator", app).waitForExistence(timeout: 5))
            try click(app.buttons["stop-recording-button"], app)
            XCTAssertTrue(app.textFields["audio-meeting-title-field"].waitForExistence(timeout: 5))
        }
        try assertDraft(path, app)
    }
    private func assertDraft(_ path: Path, _ app: XCUIApplication) throws {
        let title = app.textFields[path == .paste ? "meeting-title-field" : "audio-meeting-title-field"]
        XCTAssertEqual(title.value as? String, "Synthetic Capture Lifecycle")
        let picker = element(path == .paste ? "project-picker" : "audio-project-picker", app)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Synthetic Capture Project"), object: picker)
        wait(for: [selected], timeout: 5)
        if path == .paste {
            XCTAssertEqual(app.textViews["transcript-text-editor"].value as? String, "Synthetic capture evidence.")
        } else {
            XCTAssertTrue(app.staticTexts["selected-audio-file-label"].exists)
        }
        try AppShellUITests.validateEnvironment(app)
    }
    private func start(_ path: Path, _ app: XCUIApplication) throws {
        try click(app.buttons[path == .paste ? "save-text-meeting-button" : "start-audio-import-button"], app)
    }
    private func assertProgress(_ path: Path, _ app: XCUIApplication) throws {
        let progress = element(path == .paste ? "work-state-extraction-progress" : "capture-phase-transcribing", app)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertFalse(element("capture-completion-screen", app).exists)
        XCTAssertFalse(app.buttons[path == .paste ? "save-text-meeting-button" : "start-audio-import-button"].isEnabled)
        try AppShellUITests.validateEnvironment(app)
    }
    private func assertCompletion(_ path: Path, _ app: XCUIApplication, language: String = "ko") throws {
        XCTAssertTrue(element("capture-completion-screen", app).waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["capture-completion-meeting-title"].value as? String, "Synthetic Capture Lifecycle")
        let preservation = language == "ko"
            ? (path == .paste ? "회의와 전사문이 보존되었습니다. 오디오는 저장하지 않았습니다." : "회의, 전사문, 앱의 오디오 복사본이 보존되었습니다.")
            : (path == .paste ? "The meeting and transcript are preserved. No audio was stored." : "The meeting, transcript, and the app's audio copy are preserved.")
        XCTAssertEqual(app.staticTexts["capture-preservation-message"].value as? String, preservation)
        XCTAssertEqual(app.staticTexts["capture-candidates-heading"].value as? String,
                       language == "ko" ? "검토를 기다리는 AI 제안" : "AI proposals awaiting review")
        XCTAssertEqual(app.staticTexts["capture-unapproved-notice"].value as? String,
                       language == "ko" ? "아래 수치는 미승인 후보입니다. 개별 검토·승인 전에는 확정된 프로젝트 상태가 아닙니다."
                       : "These counts are unapproved candidates, not confirmed project state. Review and approve each proposal individually.")
        try AppShellUITests.validateEnvironment(app)
    }
    private func resultsAndSinglePendingMeeting(_ app: XCUIApplication, language: String = "ko") throws {
        try click(app.buttons["capture-open-results-button"], app)
        XCTAssertTrue(element("meeting-results-screen", app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(app.staticTexts["meeting-detail-title"].value as? String, "Synthetic Capture Lifecycle")
        try click(app.buttons["shell-rail-transcripts"], app)
        try click(app.buttons["shell-back-to-meetings"], app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-row-"))
        XCTAssertEqual(rows.count, 1, "Retry must not create a second saved meeting")
        try click(rows.firstMatch, app)
        try click(app.buttons["shell-rail-review"], app)
        XCTAssertTrue(app.staticTexts["pending-proposal-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["pending-proposal-count"].value as? String,
                       language == "ko" ? "AI 제안 4건" : "AI Suggestions: 4")
    }
    private func success(_ path: Path) throws {
        let app = try launch("success", language: "en"); defer { app.terminate() }
        try open(path, app); try start(path, app); try assertProgress(path, app)
        try assertCompletion(path, app, language: "en")
        XCTAssertFalse(app.staticTexts["capture-completion-notice"].exists)
        try resultsAndSinglePendingMeeting(app, language: "en")
    }
    private func postSave(_ path: Path, countsFail: Bool = false) throws {
        let app = try launch(countsFail ? "countReadFailure" : "analysisFailure"); defer { app.terminate() }
        try open(path, app); try start(path, app); try assertProgress(path, app)
        try assertCompletion(path, app)
        XCTAssertEqual(app.staticTexts["capture-completion-notice"].value as? String,
                       "AI 분석을 완료하지 못했습니다. AI 서버에 연결하지 못했습니다.")
        XCTAssertEqual(app.staticTexts["capture-counts-unavailable"].exists, countsFail)
        try click(app.buttons["capture-retry-analysis-button"], app)
        XCTAssertTrue(element("capture-retry-analysis-progress", app).waitForExistence(timeout: 5))
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                 object: app.buttons["capture-retry-analysis-button"])
        wait(for: [complete], timeout: 8)
        try assertCompletion(path, app)
        XCTAssertFalse(app.staticTexts["capture-counts-unavailable"].exists)
        try resultsAndSinglePendingMeeting(app)
    }
    private func preSave(_ path: Path, transcription: Bool = false) throws {
        let app = try launch(transcription ? "transcriptionFailure" : "preSaveFailure"); defer { app.terminate() }
        try open(path, app)
        let fileLabel = path == .paste ? nil : app.staticTexts["selected-audio-file-label"].value as? String
        try start(path, app)
        XCTAssertTrue(app.staticTexts[path == .paste ? "text-meeting-validation-message" : "audio-import-failed-message"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("capture-completion-screen", app).exists)
        XCTAssertFalse(app.buttons["capture-open-results-button"].exists)
        try assertDraft(path, app)
        if path != .paste { XCTAssertEqual(app.staticTexts["selected-audio-file-label"].value as? String, fileLabel) }
        XCTAssertEqual(app.staticTexts["capture-presave-message"].value as? String,
                       path == .paste ? "회의는 저장되지 않았습니다. 입력을 확인한 뒤 다시 시도하세요."
                       : "앱의 오디오 복사본은 보존되었습니다. 회의와 전사문은 아직 저장되지 않았습니다. 선택한 파일로 전사를 다시 시도하세요.")
        try start(path, app)
        try assertCompletion(path, app)
        try resultsAndSinglePendingMeeting(app)
    }
    private func cancel(_ path: Path) throws {
        let app = try launch("success"); defer { app.terminate() }
        if path == .record {
            try click(app.buttons["record-button"], app)
            try click(app.buttons["start-recording-button"], app)
            XCTAssertTrue(element("recording-indicator", app).waitForExistence(timeout: 5))
            try click(app.buttons["cancel-recording-button"], app)
            XCTAssertTrue(element("capture-phase-ready", app).waitForExistence(timeout: 5))
            try click(app.buttons["close-recording-button"], app)
        } else {
            try open(path, app)
            try click(app.buttons[path == .paste ? "cancel-text-meeting-button" : "cancel-audio-import-button"], app)
        }
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.staticTexts["home-no-meeting"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-next-action-button"].exists)
    }

    func testPasteEnglishSuccess() throws { try success(.paste) }
    func testAudioEnglishSuccess() throws { try success(.audio) }
    func testRecordEnglishSuccess() throws { try success(.record) }
    func testPasteAnalysisRetry() throws { try postSave(.paste) }
    func testAudioAnalysisRetry() throws { try postSave(.audio) }
    func testRecordAnalysisRetry() throws { try postSave(.record) }
    func testPasteCountReadFailureRetry() throws { try postSave(.paste, countsFail: true) }
    func testAudioCountReadFailureRetry() throws { try postSave(.audio, countsFail: true) }
    func testRecordCountReadFailureRetry() throws { try postSave(.record, countsFail: true) }
    func testPastePreSaveFailureRetainsDraft() throws { try preSave(.paste) }
    func testAudioPreSaveFailureRetainsSelection() throws { try preSave(.audio) }
    func testRecordPreSaveFailureRetainsSelection() throws { try preSave(.record) }
    func testAudioTranscriptionFailureAndRetry() throws { try preSave(.audio, transcription: true) }
    func testRecordTranscriptionFailureAndRetry() throws { try preSave(.record, transcription: true) }
    func testPasteCancellation() throws { try cancel(.paste) }
    func testAudioCancellation() throws { try cancel(.audio) }
    func testRecordCancellation() throws { try cancel(.record) }
}
