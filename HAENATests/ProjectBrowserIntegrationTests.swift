import XCTest
@testable import HAENA

/// Exercises the full stack the browser screens depend on: JSON persistence →
/// `TextMeetingCaptureService` → a brand-new repository instance (standing in for an app
/// relaunch) → `ProjectBrowserQueryService`. If this passes, restored data is provably
/// reachable through the same query layer the UI calls, not just present on disk.
final class ProjectBrowserIntegrationTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-ProjectBrowser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private var fileURL: URL {
        testDirectory.appendingPathComponent("projects.json")
    }

    func testSavedProjectAndMeetingAreQueryableAfterRepositoryRelaunch() async throws {
        let creationRepository = JSONProjectRepository(fileURL: fileURL)
        let creationService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )
        let project = try await creationService.createProject(name: "Browser Integration Project")

        let saveService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.laterDate },
            makeID: { TestFixtures.meetingID }
        )
        _ = try await saveService.saveTextMeeting(
            projectID: project.id,
            title: "Browser Integration Meeting",
            transcript: "Line one.\nLine two."
        )

        // A fresh repository + query service over the same file stands in for "app relaunched".
        let relaunchedRepository = JSONProjectRepository(fileURL: fileURL)
        let browserService = ProjectBrowserQueryService(repository: relaunchedRepository)

        let projects = try await browserService.loadProjects()
        let restoredProject = try XCTUnwrap(projects.first { $0.id == project.id })

        // Project detail data.
        XCTAssertEqual(restoredProject.name, "Browser Integration Project")
        XCTAssertEqual(restoredProject.meetings.count, 1)

        // Meeting list data, sorted through the same helper the detail screen uses.
        let sortedMeetings = ProjectBrowserQueryService.sortedMeetings(restoredProject.meetings)
        let restoredMeeting = try XCTUnwrap(sortedMeetings.first)
        XCTAssertEqual(restoredMeeting.title, "Browser Integration Meeting")
        XCTAssertEqual(restoredMeeting.sourceType, .pastedText)

        // Meeting detail transcript data.
        XCTAssertEqual(restoredMeeting.transcriptSegments.count, 1)
        let restoredSegment = try XCTUnwrap(restoredMeeting.transcriptSegments.first)
        XCTAssertEqual(restoredSegment.text, "Line one.\nLine two.")
        XCTAssertNil(restoredSegment.startTime)
        XCTAssertNil(restoredSegment.speakerID)
        XCTAssertNil(TranscriptSpeakerDisplay.label(for: restoredSegment, in: restoredMeeting))
        XCTAssertEqual(MeetingSourceTypeDisplay.label(for: restoredMeeting.sourceType), "텍스트 입력")
    }
}
