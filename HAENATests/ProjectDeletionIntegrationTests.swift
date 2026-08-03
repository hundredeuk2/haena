import XCTest
@testable import HAENA

/// Proves deletion is actually permanent on disk, not just removed from an in-memory cache:
/// delete through one repository instance, discard it, and check a brand-new instance over
/// the same file — standing in for an app relaunch — agrees.
final class ProjectDeletionIntegrationTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-ProjectDeletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private var fileURL: URL {
        testDirectory.appendingPathComponent("projects.json")
    }

    func testDeletedProjectDoesNotReappearAfterRepositoryRelaunch() async throws {
        let creationRepository = JSONProjectRepository(fileURL: fileURL)
        let creationService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )
        let project = try await creationService.createProject(name: "To Be Deleted")
        _ = try await creationService.saveTextMeeting(
            projectID: project.id,
            title: "Meeting",
            transcript: "Body"
        )

        let deletionService = ProjectDeletionService(repository: creationRepository)
        try await deletionService.deleteProject(id: project.id)

        // A fresh repository instance over the same file stands in for "app relaunched".
        let relaunchedRepository = JSONProjectRepository(fileURL: fileURL)
        let restoredProjects = try await relaunchedRepository.allProjects()

        XCTAssertTrue(restoredProjects.isEmpty)
        let fetched = try await relaunchedRepository.project(id: project.id)
        XCTAssertNil(fetched)
    }

    func testDeletedMeetingDoesNotReappearWhileOthersPersistAfterRepositoryRelaunch() async throws {
        let creationRepository = JSONProjectRepository(fileURL: fileURL)
        let creationService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )
        let project = try await creationService.createProject(name: "Project With Two Meetings")

        let firstMeetingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let secondMeetingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

        let firstSaveService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.laterDate },
            makeID: { firstMeetingID }
        )
        let firstMeeting = try await firstSaveService.saveTextMeeting(
            projectID: project.id,
            title: "Meeting To Delete",
            transcript: "Delete this body."
        )

        let secondSaveService = TextMeetingCaptureService(
            repository: creationRepository,
            now: { TestFixtures.laterDate },
            makeID: { secondMeetingID }
        )
        let secondMeeting = try await secondSaveService.saveTextMeeting(
            projectID: project.id,
            title: "Meeting To Keep",
            transcript: "Keep this body."
        )

        let deletionService = ProjectDeletionService(repository: creationRepository, now: { TestFixtures.laterDate })
        _ = try await deletionService.deleteMeeting(meetingID: firstMeeting.id, fromProjectID: project.id)

        // A fresh repository instance over the same file stands in for "app relaunched".
        let relaunchedRepository = JSONProjectRepository(fileURL: fileURL)
        let restoredProject = try await relaunchedRepository.project(id: project.id)

        let restored = try XCTUnwrap(restoredProject)
        XCTAssertEqual(restored.meetings.map(\.id), [secondMeeting.id])
        XCTAssertFalse(restored.meetings.contains { $0.id == firstMeeting.id })
    }
}
