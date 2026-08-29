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

    // MARK: - Continuity sidecar lifecycle

    /// A meeting deletion is an explicit user verdict that the meeting's Work State goes too, so the
    /// sidecar has to lose everything that was about it. These build the smallest sidecar that can
    /// tell a correct cleanup from an over-eager one: something to remove, and something next to it
    /// that must not move.
    private func makeProposal(
        projectID: UUID,
        sourceMeetingID: UUID,
        currentObjectID: UUID? = nil,
        previousStateID: UUID? = nil,
        relatedObjectID: UUID? = nil,
        kind: WorkStateKind = .decision,
        reviewStatus: WorkStateTransitionReviewStatus = .pendingReview
    ) -> WorkStateTransitionProposal {
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: kind,
            transitionKind: .new,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID
        ) + "|\(sourceMeetingID.uuidString.lowercased())"
        return WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
            projectID: projectID,
            workStateKind: kind,
            transitionKind: .new,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID,
            sourceMeetingID: sourceMeetingID,
            basis: .noPriorCandidate,
            requiresConfirmation: false,
            reviewStatus: reviewStatus,
            relations: relatedObjectID.map {
                [WorkStateTransitionRelation(kind: .derivedFrom, relatedKind: .actionItem, relatedObjectID: $0)]
            } ?? [],
            dedupKey: key,
            createdAt: TestFixtures.fixedDate
        )
    }

    private func makeDeletionFixture() async throws -> (
        repository: InMemoryProjectRepository,
        transitions: InMemoryWorkStateTransitionRepository,
        service: ProjectDeletionService,
        doomedMeetingID: UUID,
        keptMeetingID: UUID,
        approvedDecisionID: UUID
    ) {
        let repository = InMemoryProjectRepository()
        let doomed = makeMeeting(projectID: TestFixtures.projectID, title: "Doomed")
        let kept = makeMeeting(projectID: TestFixtures.projectID, title: "Kept")
        var approved = makeDecision(projectID: TestFixtures.projectID, meetingID: doomed.id)
        approved.status = .confirmed
        let keptDecision = makeDecision(projectID: TestFixtures.projectID, meetingID: kept.id)
        try await repository.save(makeProject(
            id: TestFixtures.projectID,
            meetings: [doomed, kept],
            decisions: [approved, keptDecision]
        ))

        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: [
                // From the doomed meeting, never reviewed.
                makeProposal(projectID: TestFixtures.projectID, sourceMeetingID: doomed.id),
                // From the doomed meeting, already given a terminal verdict.
                makeProposal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: doomed.id,
                    currentObjectID: approved.id,
                    reviewStatus: .approved
                ),
                // From the *kept* meeting, but about the object the deletion removes.
                makeProposal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: kept.id,
                    previousStateID: approved.id,
                    kind: .actionItem
                ),
                // From the kept meeting and about nothing being removed. Must survive intact.
                makeProposal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: kept.id,
                    currentObjectID: keptDecision.id,
                    kind: .openQuestion,
                    reviewStatus: .approved
                )
            ]
        )
        let service = ProjectDeletionService(
            repository: repository,
            transitions: transitions,
            now: { TestFixtures.laterDate }
        )
        return (repository, transitions, service, doomed.id, kept.id, approved.id)
    }

    func testDeletingAMeetingRemovesItsUnreviewedProposal() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.allProposals()
        XCTAssertTrue(remaining.allSatisfy { $0.sourceMeetingID != f.doomedMeetingID })
    }

    /// B: a verdict about a proposal that is going cannot be kept — there is nothing left for it to
    /// be a verdict on.
    func testDeletingAMeetingRemovesItsTerminalReviewToo() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.allProposals()
        XCTAssertFalse(remaining.contains { $0.sourceMeetingID == f.doomedMeetingID })
        XCTAssertTrue(remaining.allSatisfy { $0.reviewStatus != .approved || $0.sourceMeetingID == f.keptMeetingID })
    }

    /// A: approved canonical Work State goes with its origin meeting. No tombstone, no rehoming.
    func testDeletingAMeetingRemovesApprovedCanonicalWorkState() async throws {
        let f = try await makeDeletionFixture()
        let updated = try await f.service.deleteMeeting(
            meetingID: f.doomedMeetingID,
            fromProjectID: TestFixtures.projectID
        )

        XCTAssertFalse(updated.decisions.contains { $0.id == f.approvedDecisionID })
        XCTAssertTrue(updated.decisions.allSatisfy { $0.meetingID == f.keptMeetingID })
    }

    /// The second orphan class: a later meeting's transition whose subject this deletion removed.
    func testDeletingAMeetingCleansDependentTransitionsFromOtherMeetings() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.allProposals()
        XCTAssertFalse(
            remaining.contains { $0.previousStateID == f.approvedDecisionID },
            "a transition pointing at a removed object is the same orphan wearing a different hat"
        )
    }

    func testDeletingAMeetingLeavesUnrelatedMeetingsAndSidecarRowsIntact() async throws {
        let f = try await makeDeletionFixture()
        let before = try await f.transitions.allProposals()
            .filter { $0.sourceMeetingID == f.keptMeetingID && $0.previousStateID == nil }

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let after = try await f.transitions.allProposals()
            .filter { $0.sourceMeetingID == f.keptMeetingID && $0.previousStateID == nil }
        XCTAssertEqual(after, before, "an unrelated meeting's rows must come through unchanged")
        XCTAssertFalse(after.isEmpty)
    }

    /// Crash right after the intent, before the Project save. Recovery has to finish both halves.
    func testRecoveryFinishesADeletionInterruptedAfterTheIntent() async throws {
        let f = try await makeDeletionFixture()
        let loadedProject = try await f.repository.project(id: TestFixtures.projectID)
        let project = try XCTUnwrap(loadedProject)
        let intent = MeetingDeletionIntent(
            projectID: TestFixtures.projectID,
            meetingID: f.doomedMeetingID,
            removedWorkStateIDs: [f.approvedDecisionID],
            requestedAt: TestFixtures.fixedDate
        )
        try await f.transitions.recordMeetingDeletionIntent(intent)
        XCTAssertTrue(project.meetings.contains { $0.id == f.doomedMeetingID })

        await f.service.recoverInterruptedMeetingDeletions()

        let loadedRecovered = try await f.repository.project(id: TestFixtures.projectID)
        let recovered = try XCTUnwrap(loadedRecovered)
        XCTAssertFalse(recovered.meetings.contains { $0.id == f.doomedMeetingID })
        XCTAssertFalse(recovered.decisions.contains { $0.id == f.approvedDecisionID })
        let remaining = try await f.transitions.allProposals()
        XCTAssertTrue(remaining.allSatisfy { $0.sourceMeetingID != f.doomedMeetingID })
        let pending = try await f.transitions.pendingMeetingDeletionIntents()
        XCTAssertTrue(pending.isEmpty)
    }

    /// Crash after the Project save, before the sidecar write — the window this whole change exists
    /// to close.
    func testRecoveryFinishesADeletionInterruptedAfterTheProjectSave() async throws {
        let f = try await makeDeletionFixture()
        let loadedProject = try await f.repository.project(id: TestFixtures.projectID)
        var project = try XCTUnwrap(loadedProject)
        let intent = MeetingDeletionIntent(
            projectID: TestFixtures.projectID,
            meetingID: f.doomedMeetingID,
            removedWorkStateIDs: [f.approvedDecisionID],
            requestedAt: TestFixtures.fixedDate
        )
        try await f.transitions.recordMeetingDeletionIntent(intent)
        project.meetings.removeAll { $0.id == f.doomedMeetingID }
        project.decisions.removeAll { $0.meetingID == f.doomedMeetingID }
        try await f.repository.save(project)

        await f.service.recoverInterruptedMeetingDeletions()

        let remaining = try await f.transitions.allProposals()
        XCTAssertTrue(remaining.allSatisfy { $0.sourceMeetingID != f.doomedMeetingID })
        XCTAssertFalse(remaining.contains { $0.previousStateID == f.approvedDecisionID })
        let pending = try await f.transitions.pendingMeetingDeletionIntents()
        XCTAssertTrue(pending.isEmpty)
    }

    /// Interrupted twice must converge on the same store as interrupted once.
    func testRepeatedRecoveryChangesNothingTheSecondTime() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)
        let afterFirst = try await f.transitions.allProposals()

        await f.service.recoverInterruptedMeetingDeletions()
        await f.service.recoverInterruptedMeetingDeletions()

        let afterRecovery = try await f.transitions.allProposals()
        let stillPending = try await f.transitions.pendingMeetingDeletionIntents()
        XCTAssertEqual(afterRecovery, afterFirst)
        XCTAssertTrue(stillPending.isEmpty)
    }

    /// A sidecar written before deletions existed must still decode, and must report no pending
    /// deletions — which is exactly true of it.
    func testASidecarWithoutTheDeletionIntentFieldStillDecodes() throws {
        let legacy = """
        {"schemaVersion":1,"proposals":[]}
        """
        let decoded = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self,
            from: Data(legacy.utf8)
        )
        XCTAssertTrue(decoded.meetingDeletionIntents.isEmpty)

        var withIntent = decoded
        withIntent.meetingDeletionIntents.append(
            MeetingDeletionIntent(
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                removedWorkStateIDs: [],
                requestedAt: TestFixtures.fixedDate
            )
        )
        let roundTripped = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self,
            from: try JSONEncoder().encode(withIntent)
        )
        XCTAssertEqual(roundTripped, withIntent)
    }
}
