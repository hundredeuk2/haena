import XCTest
@testable import HAENA

final class ProjectDeletionServiceTests: XCTestCase {
    // MARK: - Fixtures

    private func makeProject(
        id: UUID = UUID(),
        name: String = "Project",
        meetings: [Meeting] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        nextAgenda: [AgendaItem] = [],
        createdAt: Date = TestFixtures.fixedDate,
        updatedAt: Date = TestFixtures.fixedDate
    ) -> Project {
        Project(
            id: id,
            name: name,
            summary: "",
            createdAt: createdAt,
            updatedAt: updatedAt,
            meetings: meetings,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            nextAgenda: nextAgenda
        )
    }

    private func makeMeeting(
        id: UUID = UUID(),
        projectID: UUID,
        title: String = "Meeting",
        occurredAt: Date = TestFixtures.fixedDate
    ) -> Meeting {
        Meeting(
            id: id,
            projectID: projectID,
            title: title,
            occurredAt: occurredAt,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
    }

    private func makeDecision(projectID: UUID, meetingID: UUID, evidence: EvidenceReference? = nil) -> Decision {
        Decision(
            id: UUID(),
            projectID: projectID,
            meetingID: meetingID,
            statement: "Statement",
            rationale: nil,
            status: .proposed,
            evidence: evidence,
            confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func makeActionItem(projectID: UUID, meetingID: UUID) -> ActionItem {
        ActionItem(
            id: UUID(),
            projectID: projectID,
            meetingID: meetingID,
            title: "Task",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .proposed,
            evidence: nil,
            confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func makeOpenQuestion(projectID: UUID, meetingID: UUID) -> OpenQuestion {
        OpenQuestion(
            id: UUID(),
            projectID: projectID,
            meetingID: meetingID,
            question: "Question?",
            status: .open,
            evidence: nil,
            confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate,
            resolvedAt: nil
        )
    }

    private func makeAgendaItem(projectID: UUID, sourceMeetingID: UUID?) -> AgendaItem {
        AgendaItem(
            id: UUID(),
            projectID: projectID,
            title: "Agenda",
            reason: "Reason",
            sourceMeetingID: sourceMeetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: TestFixtures.fixedDate
        )
    }

    /// Configurable test double so failure propagation can be tested without touching the
    /// file system or real permissions.
    private struct FailingProjectRepository: ProjectRepository {
        enum FailureMode: Sendable { case save, delete, read, none }
        enum SimulatedError: Error { case failure }

        var failureMode: FailureMode
        var stored: Project?

        func save(_ project: Project) async throws {
            if failureMode == .save { throw SimulatedError.failure }
        }

        func project(id: UUID) async throws -> Project? {
            if failureMode == .read { throw SimulatedError.failure }
            return stored?.id == id ? stored : nil
        }

        func allProjects() async throws -> [Project] {
            stored.map { [$0] } ?? []
        }

        func delete(id: UUID) async throws {
            if failureMode == .delete { throw SimulatedError.failure }
        }
    }

    // MARK: - Project deletion

    func testDeleteProjectSucceeds() async throws {
        let repository = InMemoryProjectRepository()
        let project = makeProject(id: TestFixtures.projectID)
        try await repository.save(project)

        let service = ProjectDeletionService(repository: repository)
        try await service.deleteProject(id: project.id)

        let fetched = try await repository.project(id: project.id)
        XCTAssertNil(fetched)
    }

    func testDeleteProjectRemovesAllOwnedSubData() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let project = makeProject(
            id: TestFixtures.projectID,
            meetings: [meeting],
            decisions: [makeDecision(projectID: TestFixtures.projectID, meetingID: meeting.id)],
            actionItems: [makeActionItem(projectID: TestFixtures.projectID, meetingID: meeting.id)],
            openQuestions: [makeOpenQuestion(projectID: TestFixtures.projectID, meetingID: meeting.id)],
            nextAgenda: [makeAgendaItem(projectID: TestFixtures.projectID, sourceMeetingID: meeting.id)]
        )
        try await repository.save(project)

        let service = ProjectDeletionService(repository: repository)
        try await service.deleteProject(id: project.id)

        let fetched = try await repository.project(id: project.id)
        XCTAssertNil(fetched, "Deleting the aggregate root must remove everything nested inside it")
    }

    func testDeleteProjectLeavesOtherProjectsUntouched() async throws {
        let repository = InMemoryProjectRepository()
        let idToDelete = TestFixtures.projectID
        let idToKeep = TestFixtures.meetingID // reusing a fixed UUID fixture as a second project id
        try await repository.save(makeProject(id: idToDelete, name: "Delete Me"))
        let keptProject = makeProject(id: idToKeep, name: "Keep Me")
        try await repository.save(keptProject)

        let service = ProjectDeletionService(repository: repository)
        try await service.deleteProject(id: idToDelete)

        let remaining = try await repository.allProjects()
        XCTAssertEqual(remaining, [keptProject])
    }

    func testDeleteProjectThrowsNotFoundForUnknownID() async {
        let service = ProjectDeletionService(repository: InMemoryProjectRepository())

        do {
            try await service.deleteProject(id: UUID())
            XCTFail("Expected projectNotFound")
        } catch ProjectDeletionError.projectNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteProjectPropagatesRepositoryFailureOnDelete() async {
        let repository = FailingProjectRepository(failureMode: .delete, stored: makeProject(id: TestFixtures.projectID))
        let service = ProjectDeletionService(repository: repository)

        do {
            try await service.deleteProject(id: TestFixtures.projectID)
            XCTFail("Expected repositoryFailure")
        } catch ProjectDeletionError.repositoryFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteProjectPropagatesRepositoryFailureOnRead() async {
        let repository = FailingProjectRepository(failureMode: .read, stored: nil)
        let service = ProjectDeletionService(repository: repository)

        do {
            try await service.deleteProject(id: TestFixtures.projectID)
            XCTFail("Expected repositoryFailure")
        } catch ProjectDeletionError.repositoryFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Meeting deletion

    func testDeleteMeetingRemovesOnlyThatMeeting() async throws {
        let repository = InMemoryProjectRepository()
        let keep = makeMeeting(projectID: TestFixtures.projectID, title: "Keep")
        let remove = makeMeeting(projectID: TestFixtures.projectID, title: "Remove")
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [keep, remove]))

        let service = ProjectDeletionService(repository: repository, now: { TestFixtures.laterDate })
        let updated = try await service.deleteMeeting(meetingID: remove.id, fromProjectID: TestFixtures.projectID)

        XCTAssertEqual(updated.meetings.map(\.id), [keep.id])
    }

    func testDeleteMeetingLeavesOtherProjectsMeetingsUntouched() async throws {
        let repository = InMemoryProjectRepository()
        let projectAMeeting = makeMeeting(projectID: TestFixtures.projectID)
        let otherProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let projectBMeeting = makeMeeting(projectID: otherProjectID)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [projectAMeeting]))
        let projectB = makeProject(id: otherProjectID, meetings: [projectBMeeting])
        try await repository.save(projectB)

        let service = ProjectDeletionService(repository: repository, now: { TestFixtures.laterDate })
        _ = try await service.deleteMeeting(meetingID: projectAMeeting.id, fromProjectID: TestFixtures.projectID)

        let fetchedB = try await repository.project(id: otherProjectID)
        XCTAssertEqual(fetchedB?.meetings.map(\.id), [projectBMeeting.id])
    }

    func testDeleteMeetingUpdatesProjectUpdatedAt() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting], updatedAt: TestFixtures.fixedDate))

        let service = ProjectDeletionService(repository: repository, now: { TestFixtures.laterDate })
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertEqual(updated.updatedAt, TestFixtures.laterDate)
    }

    func testDeleteMeetingSavesUpdatedProjectToRepository() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting]))

        let service = ProjectDeletionService(repository: repository, now: { TestFixtures.laterDate })
        _ = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        let fetched = try await repository.project(id: TestFixtures.projectID)
        XCTAssertEqual(fetched?.meetings, [])
        XCTAssertEqual(fetched?.updatedAt, TestFixtures.laterDate)
    }

    func testDeleteLastMeetingLeavesEmptyMeetingsArray() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting]))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.meetings.isEmpty)
    }

    func testDeleteMeetingThrowsMeetingNotFoundForUnknownMeetingID() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(makeProject(id: TestFixtures.projectID))
        let service = ProjectDeletionService(repository: repository)

        do {
            _ = try await service.deleteMeeting(meetingID: UUID(), fromProjectID: TestFixtures.projectID)
            XCTFail("Expected meetingNotFound")
        } catch ProjectDeletionError.meetingNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteMeetingThrowsProjectNotFoundForUnknownProjectID() async {
        let service = ProjectDeletionService(repository: InMemoryProjectRepository())

        do {
            _ = try await service.deleteMeeting(meetingID: UUID(), fromProjectID: UUID())
            XCTFail("Expected projectNotFound")
        } catch ProjectDeletionError.projectNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteMeetingPropagatesRepositoryFailureAndPreservesOriginalProject() async throws {
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let originalProject = makeProject(id: TestFixtures.projectID, meetings: [meeting])
        let repository = FailingProjectRepository(failureMode: .save, stored: originalProject)
        let service = ProjectDeletionService(repository: repository)

        do {
            _ = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)
            XCTFail("Expected repositoryFailure")
        } catch ProjectDeletionError.repositoryFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // The failed save never happened, so a fresh read still returns the untouched original.
        let fetched = try await repository.project(id: TestFixtures.projectID)
        XCTAssertEqual(fetched, originalProject)
    }

    // MARK: - Orphan reference cleanup

    func testDeleteMeetingRemovesDecisionsReferencingIt() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let decision = makeDecision(projectID: TestFixtures.projectID, meetingID: meeting.id)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting], decisions: [decision]))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.decisions.isEmpty)
    }

    func testDeleteMeetingRemovesActionItemsReferencingIt() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let actionItem = makeActionItem(projectID: TestFixtures.projectID, meetingID: meeting.id)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting], actionItems: [actionItem]))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.actionItems.isEmpty)
    }

    func testDeleteMeetingRemovesOpenQuestionsReferencingIt() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let openQuestion = makeOpenQuestion(projectID: TestFixtures.projectID, meetingID: meeting.id)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting], openQuestions: [openQuestion]))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.openQuestions.isEmpty)
    }

    func testDeleteMeetingRemovesAgendaItemsSourcedFromIt() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let agendaItem = makeAgendaItem(projectID: TestFixtures.projectID, sourceMeetingID: meeting.id)
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting], nextAgenda: [agendaItem]))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.nextAgenda.isEmpty)
    }

    func testDeleteMeetingPreservesDerivedStateForOtherMeetings() async throws {
        let repository = InMemoryProjectRepository()
        let meetingToDelete = makeMeeting(projectID: TestFixtures.projectID, title: "Delete")
        let meetingToKeep = makeMeeting(projectID: TestFixtures.projectID, title: "Keep")

        let decisionToDelete = makeDecision(projectID: TestFixtures.projectID, meetingID: meetingToDelete.id)
        let decisionToKeep = makeDecision(projectID: TestFixtures.projectID, meetingID: meetingToKeep.id)
        let actionItemToKeep = makeActionItem(projectID: TestFixtures.projectID, meetingID: meetingToKeep.id)
        let openQuestionToKeep = makeOpenQuestion(projectID: TestFixtures.projectID, meetingID: meetingToKeep.id)
        let agendaItemToKeep = makeAgendaItem(projectID: TestFixtures.projectID, sourceMeetingID: meetingToKeep.id)

        try await repository.save(makeProject(
            id: TestFixtures.projectID,
            meetings: [meetingToDelete, meetingToKeep],
            decisions: [decisionToDelete, decisionToKeep],
            actionItems: [actionItemToKeep],
            openQuestions: [openQuestionToKeep],
            nextAgenda: [agendaItemToKeep]
        ))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meetingToDelete.id, fromProjectID: TestFixtures.projectID)

        XCTAssertEqual(updated.meetings.map(\.id), [meetingToKeep.id])
        XCTAssertEqual(updated.decisions.map(\.id), [decisionToKeep.id])
        XCTAssertEqual(updated.actionItems.map(\.id), [actionItemToKeep.id])
        XCTAssertEqual(updated.openQuestions.map(\.id), [openQuestionToKeep.id])
        XCTAssertEqual(updated.nextAgenda.map(\.id), [agendaItemToKeep.id])
    }

    func testDeleteMeetingRemovesEmbeddedEvidenceAlongWithItsOwningDecision() async throws {
        let repository = InMemoryProjectRepository()
        let meeting = makeMeeting(projectID: TestFixtures.projectID)
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: meeting.id,
            speakerID: nil,
            text: "본문",
            startTime: nil,
            endTime: nil
        )
        var meetingWithSegment = meeting
        meetingWithSegment.transcriptSegments = [segment]

        let evidence = EvidenceReference(meetingID: meeting.id, transcriptSegmentID: segment.id, quote: "본문")
        let decisionWithEvidence = makeDecision(projectID: TestFixtures.projectID, meetingID: meeting.id, evidence: evidence)

        try await repository.save(makeProject(
            id: TestFixtures.projectID,
            meetings: [meetingWithSegment],
            decisions: [decisionWithEvidence]
        ))

        let service = ProjectDeletionService(repository: repository)
        let updated = try await service.deleteMeeting(meetingID: meeting.id, fromProjectID: TestFixtures.projectID)

        XCTAssertTrue(updated.decisions.isEmpty, "The Decision — and the EvidenceReference embedded inside it — must both be gone")
    }
}
