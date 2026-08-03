import XCTest
@testable import HAENA

final class TextMeetingCaptureServiceTests: XCTestCase {
    // MARK: - Project creation validation

    func testCreateProjectRejectsEmptyName() async {
        let service = TextMeetingCaptureService(
            repository: InMemoryProjectRepository(),
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )

        do {
            _ = try await service.createProject(name: "")
            XCTFail("Expected projectNameMissing")
        } catch TextMeetingCaptureError.projectNameMissing {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateProjectRejectsWhitespaceOnlyName() async {
        let service = TextMeetingCaptureService(
            repository: InMemoryProjectRepository(),
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )

        do {
            _ = try await service.createProject(name: "   ")
            XCTFail("Expected projectNameMissing")
        } catch TextMeetingCaptureError.projectNameMissing {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateProjectTrimsWhitespaceFromName() async throws {
        let service = TextMeetingCaptureService(
            repository: InMemoryProjectRepository(),
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )

        let project = try await service.createProject(name: "  HAE.NA MVP  ")

        XCTAssertEqual(project.name, "HAE.NA MVP")
    }

    // MARK: - Project creation

    func testCreateProjectSavesToRepository() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(
            repository: repository,
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )

        let project = try await service.createProject(name: "HAE.NA MVP")
        let fetched = try await repository.project(id: TestFixtures.projectID)

        XCTAssertEqual(project.id, TestFixtures.projectID)
        XCTAssertEqual(project.createdAt, TestFixtures.fixedDate)
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate)
        XCTAssertEqual(fetched, project)
    }

    /// Decision: project names are not required to be unique. Identity is the UUID, not the
    /// name, and the product spec never asked for name-collision handling, so the simplest
    /// policy — allow duplicates — was chosen over adding an uniqueness check nobody requested.
    func testCreatingTwoProjectsWithSameNameYieldsDifferentIDs() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate })

        let first = try await service.createProject(name: "Weekly Sync")
        let second = try await service.createProject(name: "Weekly Sync")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.name, second.name)
    }

    // MARK: - Meeting save validation

    func testSaveTextMeetingRejectsMissingProjectSelection() async {
        let service = TextMeetingCaptureService(repository: InMemoryProjectRepository())

        do {
            _ = try await service.saveTextMeeting(projectID: nil, title: "제목", transcript: "본문")
            XCTFail("Expected noProjectSelected")
        } catch TextMeetingCaptureError.noProjectSelected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveTextMeetingRejectsEmptyTitle() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await service.createProject(name: "Project")

        do {
            _ = try await service.saveTextMeeting(projectID: project.id, title: "", transcript: "본문")
            XCTFail("Expected meetingTitleMissing")
        } catch TextMeetingCaptureError.meetingTitleMissing {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveTextMeetingRejectsWhitespaceOnlyTitle() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await service.createProject(name: "Project")

        do {
            _ = try await service.saveTextMeeting(projectID: project.id, title: "   ", transcript: "본문")
            XCTFail("Expected meetingTitleMissing")
        } catch TextMeetingCaptureError.meetingTitleMissing {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveTextMeetingRejectsEmptyTranscript() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await service.createProject(name: "Project")

        do {
            _ = try await service.saveTextMeeting(projectID: project.id, title: "제목", transcript: "")
            XCTFail("Expected transcriptMissing")
        } catch TextMeetingCaptureError.transcriptMissing {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveTextMeetingRejectsWhitespaceOnlyTranscript() async throws {
        let repository = InMemoryProjectRepository()
        let service = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await service.createProject(name: "Project")

        do {
            _ = try await service.saveTextMeeting(projectID: project.id, title: "제목", transcript: "   ")
            XCTFail("Expected transcriptMissing")
        } catch TextMeetingCaptureError.transcriptMissing {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveTextMeetingRejectsUnknownProjectID() async {
        let service = TextMeetingCaptureService(
            repository: InMemoryProjectRepository(),
            now: { TestFixtures.fixedDate }
        )

        do {
            _ = try await service.saveTextMeeting(projectID: TestFixtures.projectID, title: "제목", transcript: "본문")
            XCTFail("Expected projectNotFound")
        } catch TextMeetingCaptureError.projectNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Meeting save data flow

    func testSaveTextMeetingTrimsWhitespaceFromTitleAndTranscript() async throws {
        let repository = InMemoryProjectRepository()
        let creationService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await creationService.createProject(name: "Project")

        let saveService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.laterDate }, makeID: { TestFixtures.meetingID })
        let meeting = try await saveService.saveTextMeeting(
            projectID: project.id,
            title: "  킥오프 회의  ",
            transcript: "  오늘 결정된 내용입니다.  "
        )

        XCTAssertEqual(meeting.title, "킥오프 회의")
        XCTAssertEqual(meeting.transcriptSegments.first?.text, "오늘 결정된 내용입니다.")
    }

    func testSaveTextMeetingCreatesPastedTextMeetingWithSingleSegment() async throws {
        let repository = InMemoryProjectRepository()
        let creationService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await creationService.createProject(name: "Project")

        let saveService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.laterDate }, makeID: { TestFixtures.meetingID })
        let meeting = try await saveService.saveTextMeeting(
            projectID: project.id,
            title: "킥오프 회의",
            transcript: "오늘 결정된 내용입니다."
        )

        XCTAssertEqual(meeting.sourceType, .pastedText)
        XCTAssertEqual(meeting.projectID, project.id)
        XCTAssertEqual(meeting.occurredAt, TestFixtures.laterDate)
        XCTAssertEqual(meeting.transcriptSegments.count, 1)

        let segment = try XCTUnwrap(meeting.transcriptSegments.first)
        XCTAssertEqual(segment.meetingID, meeting.id)
        XCTAssertEqual(segment.text, "오늘 결정된 내용입니다.")
        XCTAssertNil(segment.startTime)
        XCTAssertNil(segment.endTime)
        XCTAssertNil(segment.speakerID)
    }

    func testSaveTextMeetingAppendsMeetingAndAdvancesProjectUpdatedAt() async throws {
        let repository = InMemoryProjectRepository()
        let creationService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.fixedDate }, makeID: { TestFixtures.projectID })
        let project = try await creationService.createProject(name: "Project")
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate)

        let saveService = TextMeetingCaptureService(repository: repository, now: { TestFixtures.laterDate }, makeID: { TestFixtures.meetingID })
        let meeting = try await saveService.saveTextMeeting(
            projectID: project.id,
            title: "킥오프 회의",
            transcript: "오늘 결정된 내용입니다."
        )

        let fetchedProject = try await repository.project(id: project.id)
        let updatedProject = try XCTUnwrap(fetchedProject)
        XCTAssertEqual(updatedProject.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(updatedProject.updatedAt, TestFixtures.laterDate)
    }
}
