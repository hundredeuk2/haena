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
        XCTAssertNil(segment.sourceSpeakerLabel)
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

    func testStructuredDraftStoresMultipleTurnsWithFreshMeetingParticipants() async throws {
        let repository = InMemoryProjectRepository(projects: [Self.emptyProject()])
        let ids = AudioTestSupport.IDSequence()
        let firstDraftID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondDraftID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let service = TextMeetingCaptureService(
            repository: repository,
            now: { TestFixtures.laterDate },
            makeID: { ids.next() }
        )

        let meeting = try await service.saveTextMeeting(
            projectID: TestFixtures.projectID,
            title: "구조화 회의",
            draft: PastedTranscriptDraft(
                participants: [
                    PastedParticipantDraft(id: firstDraftID, displayName: "참석자 A", provenance: .userEntered),
                    PastedParticipantDraft(id: secondDraftID, displayName: "참석자 B", provenance: .selectedProjectNameCandidate)
                ],
                turns: [
                    PastedTranscriptTurnDraft(
                        id: UUID(), text: "제가 초안을 작성하겠습니다.",
                        sourceSpeakerLabel: "A", selectedParticipantDraftID: firstDraftID
                    ),
                    PastedTranscriptTurnDraft(
                        id: UUID(), text: "검토는 제가 맡겠습니다.",
                        sourceSpeakerLabel: "B", selectedParticipantDraftID: secondDraftID
                    ),
                    PastedTranscriptTurnDraft(
                        id: UUID(), text: "일정은 아직 미정입니다.",
                        sourceSpeakerLabel: "C", selectedParticipantDraftID: nil
                    )
                ]
            )
        )

        XCTAssertEqual(meeting.participants.map(\.displayName), ["참석자 A", "참석자 B"])
        XCTAssertFalse(meeting.participants.map(\.id).contains(firstDraftID))
        XCTAssertFalse(meeting.participants.map(\.id).contains(secondDraftID))
        XCTAssertEqual(meeting.transcriptSegments.map(\.sourceSpeakerLabel), ["A", "B", "C"])
        XCTAssertEqual(meeting.transcriptSegments[0].speakerID, meeting.participants[0].id)
        XCTAssertEqual(meeting.transcriptSegments[1].speakerID, meeting.participants[1].id)
        XCTAssertNil(meeting.transcriptSegments[2].speakerID)

        let reloaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(reloaded)
        XCTAssertEqual(stored.meetings, [meeting])
    }

    func testStructuredDraftPreservesUnlinkedSourceLabel() async throws {
        let repository = InMemoryProjectRepository(projects: [Self.emptyProject()])
        let meeting = try await TextMeetingCaptureService(repository: repository).saveTextMeeting(
            projectID: TestFixtures.projectID,
            title: "미연결 회의",
            draft: PastedTranscriptDraft(
                participants: [],
                turns: [
                    PastedTranscriptTurnDraft(
                        id: UUID(), text: "담당자는 나중에 정합니다.",
                        sourceSpeakerLabel: "Speaker C", selectedParticipantDraftID: nil
                    )
                ]
            )
        )

        XCTAssertEqual(meeting.transcriptSegments[0].sourceSpeakerLabel, "Speaker C")
        XCTAssertNil(meeting.transcriptSegments[0].speakerID)
    }

    func testStructuredDraftPreservesExactSourceLabelAndOriginalTurnText() async throws {
        let repository = InMemoryProjectRepository(projects: [Self.emptyProject()])
        let meeting = try await TextMeetingCaptureService(repository: repository).saveTextMeeting(
            projectID: TestFixtures.projectID,
            title: "Exact source",
            draft: PastedTranscriptDraft(
                participants: [],
                turns: [
                    PastedTranscriptTurnDraft(
                        id: UUID(),
                        text: "  original body\n",
                        sourceSpeakerLabel: " Speaker A ",
                        selectedParticipantDraftID: nil
                    )
                ]
            )
        )

        XCTAssertEqual(meeting.transcriptSegments[0].sourceSpeakerLabel, " Speaker A ")
        XCTAssertEqual(meeting.transcriptSegments[0].text, "  original body\n")
    }

    func testPriorRosterCandidatesPreserveDuplicateOccurrencesWithoutReusingIdentity() async throws {
        let firstID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        var project = Self.emptyProject()
        project.meetings = [
            Self.meeting(id: UUID(), title: "1차", participantID: firstID, name: "동명이인", label: "A"),
            Self.meeting(id: UUID(), title: "2차", participantID: secondID, name: "동명이인", label: "B")
        ]
        let repository = InMemoryProjectRepository(projects: [project])
        let candidates = try await TextMeetingCaptureService(repository: repository)
            .participantNameCandidates(projectID: project.id)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.displayName), ["동명이인", "동명이인"])
        XCTAssertNotEqual(candidates[0].id, candidates[1].id)
        XCTAssertEqual(candidates.map(\.sourceSpeakerLabel), ["A", "B"])
    }

    func testStructuredSaveFailureDoesNotPolluteStoredProject() async throws {
        let original = Self.emptyProject()
        let repository = FailingTextMeetingSaveRepository(stored: original)
        let draftID = UUID()
        let service = TextMeetingCaptureService(repository: repository)

        do {
            _ = try await service.saveTextMeeting(
                projectID: original.id,
                title: "저장 실패",
                draft: PastedTranscriptDraft(
                    participants: [
                        PastedParticipantDraft(id: draftID, displayName: "참석자", provenance: .userEntered)
                    ],
                    turns: [
                        PastedTranscriptTurnDraft(
                            id: UUID(), text: "제가 하겠습니다.",
                            sourceSpeakerLabel: "A", selectedParticipantDraftID: draftID
                        )
                    ]
                )
            )
            XCTFail("expected save failure")
        } catch is TextMeetingCaptureError {
            XCTFail("repository failure must not be rewritten as validation")
        } catch {
            // expected
        }

        let reloaded = try await repository.project(id: original.id)
        let stored = try XCTUnwrap(reloaded)
        XCTAssertEqual(stored, original)
        XCTAssertTrue(stored.meetings.isEmpty)
    }

    private static func emptyProject() -> Project {
        Project(
            id: TestFixtures.projectID,
            name: "Project",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    private static func meeting(
        id: UUID,
        title: String,
        participantID: UUID,
        name: String,
        label: String
    ) -> Meeting {
        Meeting(
            id: id,
            projectID: TestFixtures.projectID,
            title: title,
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [
                Participant(id: participantID, displayName: name, linkedUserID: nil, speakerLabel: label)
            ],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
    }
}

private actor FailingTextMeetingSaveRepository: ProjectRepository {
    private let stored: Project

    init(stored: Project) {
        self.stored = stored
    }

    func save(_ project: Project) async throws {
        throw FailingTextMeetingSaveError.expected
    }

    func allProjects() async throws -> [Project] { [stored] }
    func project(id: UUID) async throws -> Project? { id == stored.id ? stored : nil }
    func delete(id: UUID) async throws {}
}

private enum FailingTextMeetingSaveError: Error {
    case expected
}
