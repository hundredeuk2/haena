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

    /// A second project that no deletion in this file ever targets.
    private static let otherProjectID = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!

    /// The ambiguity rows the fixture plants, named so a test can say which one it means instead of
    /// re-deriving a dedupKey.
    private struct DeletionFixtureGroups {
        let bySourceMeeting: WorkStateAmbiguousMatchGroup
        let byIncomingObject: WorkStateAmbiguousMatchGroup
        /// The removed object sorts *first* among this group's candidates.
        let byFirstCandidate: WorkStateAmbiguousMatchGroup
        /// The removed object sorts *last* among this group's candidates.
        let byLastCandidate: WorkStateAmbiguousMatchGroup
        let unrelated: WorkStateAmbiguousMatchGroup
        let otherProject: WorkStateAmbiguousMatchGroup
    }

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

    /// Refusals carry the same two typed object references a proposal does, and no `relations`.
    /// `reason` is what keeps each fixture row's `dedupKey` distinct, so the assertions below can
    /// name a specific record instead of counting anonymous rows.
    private func makeRefusal(
        projectID: UUID,
        sourceMeetingID: UUID,
        currentObjectID: UUID? = nil,
        previousStateID: UUID? = nil,
        reason: WorkStateTransitionReason
    ) -> WorkStateTransitionRefusalRecord {
        WorkStateTransitionRefusalRecord(
            run: WorkStateContinuityRunIdentity(
                projectID: projectID,
                sourceMeetingID: sourceMeetingID
            ),
            refusal: WorkStateTransitionRefusal(
                workStateKind: .decision,
                attemptedTransition: nil,
                previousStateID: previousStateID,
                currentObjectID: currentObjectID,
                reason: reason
            ),
            createdAt: TestFixtures.fixedDate
        )
    }

    /// A group is a question about identity, so it names one incoming object and every prior
    /// candidate it could be. `priorCandidateIDs` is de-duplicated and sorted by lowercased UUID
    /// string inside the initialiser, so the tests below read the position they mean back off the
    /// constructed value rather than assuming the order they passed in survived.
    private func makeAmbiguityGroup(
        projectID: UUID,
        sourceMeetingID: UUID,
        incomingObjectID: UUID,
        priorCandidateIDs: [UUID],
        kind: WorkStateKind = .actionItem
    ) -> WorkStateAmbiguousMatchGroup {
        WorkStateAmbiguousMatchGroup(
            projectID: projectID,
            sourceMeetingID: sourceMeetingID,
            workStateKind: kind,
            incomingObjectID: incomingObjectID,
            priorCandidateIDs: priorCandidateIDs
        )
    }

    private func makeAmbiguityReview(
        group: WorkStateAmbiguousMatchGroup
    ) -> WorkStateAmbiguityReviewState {
        WorkStateAmbiguityReviewState(
            groupID: group.id,
            projectID: group.projectID,
            selectionKind: .new,
            selectedPriorStateID: nil,
            reviewedAt: TestFixtures.fixedDate
        )
    }

    private func makeDeletionFixture() async throws -> (
        repository: InMemoryProjectRepository,
        transitions: InMemoryWorkStateTransitionRepository,
        service: ProjectDeletionService,
        doomedMeetingID: UUID,
        keptMeetingID: UUID,
        approvedDecisionID: UUID,
        keptDecisionID: UUID,
        groups: DeletionFixtureGroups
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

        // Candidate ids chosen so the removed object lands at a known position once the group
        // sorts them: `low` < approved < `high` by lowercased UUID string.
        let low = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
        let high = UUID(uuidString: "FFFFFFFF-0000-4000-8000-0000000000BB")!
        let groups = DeletionFixtureGroups(
            // From the doomed meeting. Removed by the original `sourceMeetingID` rule.
            bySourceMeeting: makeAmbiguityGroup(
                projectID: TestFixtures.projectID,
                sourceMeetingID: doomed.id,
                incomingObjectID: keptDecision.id,
                priorCandidateIDs: [low]
            ),
            // From the *kept* meeting, asking about the object this deletion removes.
            byIncomingObject: makeAmbiguityGroup(
                projectID: TestFixtures.projectID,
                sourceMeetingID: kept.id,
                incomingObjectID: approved.id,
                priorCandidateIDs: [low, high]
            ),
            byFirstCandidate: makeAmbiguityGroup(
                projectID: TestFixtures.projectID,
                sourceMeetingID: kept.id,
                incomingObjectID: keptDecision.id,
                priorCandidateIDs: [approved.id, high],
                kind: .decision
            ),
            byLastCandidate: makeAmbiguityGroup(
                projectID: TestFixtures.projectID,
                sourceMeetingID: kept.id,
                incomingObjectID: keptDecision.id,
                priorCandidateIDs: [low, approved.id],
                kind: .openQuestion
            ),
            // Names nothing being removed. Must come through unchanged.
            unrelated: makeAmbiguityGroup(
                projectID: TestFixtures.projectID,
                sourceMeetingID: kept.id,
                incomingObjectID: keptDecision.id,
                priorCandidateIDs: [low, high]
            ),
            // Another project naming the very object being deleted. Survives on the guard alone.
            otherProject: makeAmbiguityGroup(
                projectID: Self.otherProjectID,
                sourceMeetingID: kept.id,
                incomingObjectID: approved.id,
                priorCandidateIDs: [approved.id, low]
            )
        )

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
            ],
            ambiguousMatchGroups: [
                groups.bySourceMeeting, groups.byIncomingObject, groups.byFirstCandidate,
                groups.byLastCandidate, groups.unrelated, groups.otherProject
            ],
            ambiguityReviews: [
                makeAmbiguityReview(group: groups.byIncomingObject),
                makeAmbiguityReview(group: groups.unrelated),
                makeAmbiguityReview(group: groups.otherProject)
            ],
            // Removal targets and preservation targets sit in the same sidecar on purpose: a
            // cleanup that is too eager and one that is too timid both fail here, and neither
            // would show up in a fixture that only contained rows expected to disappear.
            refusals: [
                // From the doomed meeting. Removed by the original `sourceMeetingID` rule.
                makeRefusal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: doomed.id,
                    reason: .missingEvidence
                ),
                // From the *kept* meeting, explaining a refusal about the object being deleted.
                makeRefusal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: kept.id,
                    currentObjectID: approved.id,
                    reason: .similarityOnly
                ),
                makeRefusal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: kept.id,
                    previousStateID: approved.id,
                    reason: .priorItemNotApproved
                ),
                // From the kept meeting and about an object that survives. Must come through
                // unchanged.
                makeRefusal(
                    projectID: TestFixtures.projectID,
                    sourceMeetingID: kept.id,
                    currentObjectID: keptDecision.id,
                    reason: .stateChangeRequiresApproval
                ),
                // Another project, pointing at the *same* object UUID this deletion removes. It is
                // the sharpest form of the scoping question: nothing but the project guard keeps
                // this row alive.
                makeRefusal(
                    projectID: Self.otherProjectID,
                    sourceMeetingID: kept.id,
                    currentObjectID: approved.id,
                    reason: .crossProjectCandidate
                )
            ]
        )
        let service = ProjectDeletionService(
            repository: repository,
            transitions: transitions,
            now: { TestFixtures.laterDate }
        )
        // A durable apply intent for a doomed group, so the intent path is exercised through the
        // same closure rather than only in principle.
        _ = try await transitions.prepareApplyIntent(
            WorkStateTransitionApplyIntent.ambiguity(
                projectID: TestFixtures.projectID,
                groupID: groups.byIncomingObject.id,
                selection: .new,
                reviewedAt: TestFixtures.fixedDate
            )
        )
        // And one for a group that survives, which must still be there afterwards.
        _ = try await transitions.prepareApplyIntent(
            WorkStateTransitionApplyIntent.ambiguity(
                projectID: TestFixtures.projectID,
                groupID: groups.unrelated.id,
                selection: .new,
                reviewedAt: TestFixtures.fixedDate
            )
        )

        return (
            repository, transitions, service,
            doomed.id, kept.id, approved.id, keptDecision.id, groups
        )
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

    // MARK: - Refusal object-reference orphans

    /// A refusal explains why one object could not be carried forward. Once that object is gone the
    /// explanation has no subject left, so it goes with it — even though the refusal itself came
    /// from a meeting nobody deleted.
    func testDeletingAMeetingRemovesAnotherMeetingsRefusalPointingAtItByCurrentObjectID() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.refusals(forProject: TestFixtures.projectID)
        XCTAssertFalse(
            remaining.contains { $0.currentObjectID == f.approvedDecisionID },
            "a refusal about a deleted object is not an audit record, it is a dangling reference"
        )
    }

    func testDeletingAMeetingRemovesAnotherMeetingsRefusalPointingAtItByPreviousStateID() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.refusals(forProject: TestFixtures.projectID)
        XCTAssertFalse(remaining.contains { $0.previousStateID == f.approvedDecisionID })
    }

    /// The over-deletion guard: a refusal in the same project, from the same surviving meeting, is
    /// kept whole — same record, not merely the same count.
    func testDeletingAMeetingKeepsSameProjectRefusalsAboutSurvivingObjects() async throws {
        let f = try await makeDeletionFixture()
        let before = try await f.transitions.refusals(forProject: TestFixtures.projectID)
            .filter { $0.currentObjectID == f.keptDecisionID }
        XCTAssertFalse(before.isEmpty)

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let after = try await f.transitions.refusals(forProject: TestFixtures.projectID)
            .filter { $0.currentObjectID == f.keptDecisionID }
        XCTAssertEqual(after, before)
    }

    /// The scoping guard. This row points at the very object being deleted, by the same UUID, and
    /// survives for one reason only: it belongs to another project.
    func testDeletingAMeetingNeverReachesAnotherProjectsRefusals() async throws {
        let f = try await makeDeletionFixture()
        let before = try await f.transitions.refusals(forProject: Self.otherProjectID)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?.currentObjectID, f.approvedDecisionID)

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let after = try await f.transitions.refusals(forProject: Self.otherProjectID)
        XCTAssertEqual(after, before, "deletion must not cross a project boundary on a bare UUID")
    }

    /// The rule that was already there stays there: the object-reference paths are an addition to
    /// `sourceMeetingID`, not a replacement for it.
    func testDeletingAMeetingStillRemovesItsOwnRefusalsBySourceMeeting() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.allRefusals()
        XCTAssertFalse(remaining.contains { $0.sourceMeetingID == f.doomedMeetingID })
    }

    // MARK: - Ambiguity group object-reference orphans

    /// A group asks "is this incoming object one of these prior ones, or new?". Delete the incoming
    /// object and the question has no subject left, even though the group came from a meeting
    /// nobody deleted.
    func testDeletingAMeetingRemovesAnotherMeetingsGroupByIncomingObjectID() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.ambiguousMatchGroups(forProject: TestFixtures.projectID)
        XCTAssertFalse(remaining.contains { $0.id == f.groups.byIncomingObject.id })
    }

    /// Delete a candidate and the answer set changes under a user who has not answered yet, so the
    /// group goes rather than quietly offering fewer choices. First position in the sorted order.
    func testDeletingAMeetingRemovesAGroupWhoseFirstPriorCandidateIsDeleted() async throws {
        let f = try await makeDeletionFixture()
        XCTAssertEqual(
            f.groups.byFirstCandidate.priorCandidateIDs.first, f.approvedDecisionID,
            "fixture must actually place the removed object first once the group sorts candidates"
        )

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.ambiguousMatchGroups(forProject: TestFixtures.projectID)
        XCTAssertFalse(remaining.contains { $0.id == f.groups.byFirstCandidate.id })
    }

    /// Same rule at the other end of the array — the closure must not be scanning only position 0.
    func testDeletingAMeetingRemovesAGroupWhoseLastPriorCandidateIsDeleted() async throws {
        let f = try await makeDeletionFixture()
        XCTAssertEqual(
            f.groups.byLastCandidate.priorCandidateIDs.last, f.approvedDecisionID,
            "fixture must actually place the removed object last once the group sorts candidates"
        )

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.ambiguousMatchGroups(forProject: TestFixtures.projectID)
        XCTAssertFalse(remaining.contains { $0.id == f.groups.byLastCandidate.id })
    }

    /// A selection recorded against a group that is going has nothing left to select from.
    func testDeletingAMeetingRemovesTheReviewOfADependentGroup() async throws {
        let f = try await makeDeletionFixture()
        let before = try await f.transitions.ambiguityReview(groupID: f.groups.byIncomingObject.id)
        XCTAssertNotNil(before)

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let after = try await f.transitions.ambiguityReview(groupID: f.groups.byIncomingObject.id)
        XCTAssertNil(after, "a selection outliving its question is unreachable, not preserved")
    }

    /// Left behind, recovery would try to finish an operation whose group no longer exists.
    func testDeletingAMeetingRemovesAnApplyIntentForADependentGroup() async throws {
        let f = try await makeDeletionFixture()
        let before = try await f.transitions.pendingApplyIntents()
        XCTAssertTrue(before.contains { $0.operationID == f.groups.byIncomingObject.id })

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let after = try await f.transitions.pendingApplyIntents()
        XCTAssertFalse(after.contains { $0.operationID == f.groups.byIncomingObject.id })
        XCTAssertTrue(
            after.contains { $0.operationID == f.groups.unrelated.id },
            "an intent for a surviving group must not be swept up with it"
        )
    }

    /// The over-deletion guard: a group naming nothing that was removed comes through whole, and so
    /// does the selection recorded against it.
    func testDeletingAMeetingKeepsUnrelatedGroupsAndTheirReviews() async throws {
        let f = try await makeDeletionFixture()
        let reviewBefore = try await f.transitions.ambiguityReview(groupID: f.groups.unrelated.id)

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.ambiguousMatchGroups(forProject: TestFixtures.projectID)
        let kept = remaining.first { $0.id == f.groups.unrelated.id }
        XCTAssertEqual(kept, f.groups.unrelated)
        let reviewAfter = try await f.transitions.ambiguityReview(groupID: f.groups.unrelated.id)
        XCTAssertEqual(reviewAfter, reviewBefore)
        XCTAssertNotNil(reviewAfter)
    }

    /// The scoping guard. This group names the deleted object twice — as its incoming object and as
    /// a candidate — and survives for one reason only: it belongs to another project.
    func testDeletingAMeetingNeverReachesAnotherProjectsGroupsOrReviews() async throws {
        let f = try await makeDeletionFixture()
        let reviewBefore = try await f.transitions.ambiguityReview(groupID: f.groups.otherProject.id)
        XCTAssertNotNil(reviewBefore)
        XCTAssertEqual(f.groups.otherProject.incomingObjectID, f.approvedDecisionID)

        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.ambiguousMatchGroups(forProject: Self.otherProjectID)
        XCTAssertEqual(remaining, [f.groups.otherProject])
        let reviewAfter = try await f.transitions.ambiguityReview(groupID: f.groups.otherProject.id)
        XCTAssertEqual(reviewAfter, reviewBefore)
    }

    /// The object-reference paths are an addition to `sourceMeetingID`, not a replacement.
    func testDeletingAMeetingStillRemovesItsOwnGroupsBySourceMeeting() async throws {
        let f = try await makeDeletionFixture()
        try await f.service.deleteMeeting(meetingID: f.doomedMeetingID, fromProjectID: TestFixtures.projectID)

        let remaining = try await f.transitions.allAmbiguousMatchGroups()
        XCTAssertFalse(remaining.contains { $0.sourceMeetingID == f.doomedMeetingID })
    }

    // MARK: - Project deletion sidecar lifecycle

    /// Refuses only the project-scoped sweep, and only that: everything before it succeeds, so the
    /// aggregate is already gone by the time this throws.
    private actor SidecarFailingOnProjectSweep: WorkStateTransitionRepository {
        enum SimulatedError: Error { case sweep }

        private let base: InMemoryWorkStateTransitionRepository

        init(base: InMemoryWorkStateTransitionRepository) { self.base = base }

        func applyProjectDeletion(_ intent: ProjectDeletionIntent) async throws {
            throw SimulatedError.sweep
        }

        func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) async throws {
            try await base.recordProjectDeletionIntent(intent)
        }
        func pendingProjectDeletionIntents() async throws -> [ProjectDeletionIntent] {
            try await base.pendingProjectDeletionIntents()
        }
        func proposals(forProject projectID: UUID) async throws -> [WorkStateTransitionProposal] {
            try await base.proposals(forProject: projectID)
        }
        func allProposals() async throws -> [WorkStateTransitionProposal] {
            try await base.allProposals()
        }
        func ambiguousMatchGroups(forProject projectID: UUID) async throws -> [WorkStateAmbiguousMatchGroup] {
            try await base.ambiguousMatchGroups(forProject: projectID)
        }
        func allAmbiguousMatchGroups() async throws -> [WorkStateAmbiguousMatchGroup] {
            try await base.allAmbiguousMatchGroups()
        }
        func ambiguityReview(groupID: UUID) async throws -> WorkStateAmbiguityReviewState? {
            try await base.ambiguityReview(groupID: groupID)
        }
        func refusals(forProject projectID: UUID) async throws -> [WorkStateTransitionRefusalRecord] {
            try await base.refusals(forProject: projectID)
        }
        func allRefusals() async throws -> [WorkStateTransitionRefusalRecord] {
            try await base.allRefusals()
        }
        func upsert(_ proposals: [WorkStateTransitionProposal]) async throws {
            try await base.upsert(proposals)
        }
        func upsert(
            proposals: [WorkStateTransitionProposal],
            ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
            refusals: [WorkStateTransitionRefusalRecord]
        ) async throws {
            try await base.upsert(
                proposals: proposals, ambiguousMatchGroups: ambiguousMatchGroups, refusals: refusals
            )
        }
        func recordTerminalReview(
            projectID: UUID, proposalID: UUID, verdict: WorkStateTransitionTerminalVerdict
        ) async throws -> WorkStateTransitionReviewWriteResult {
            try await base.recordTerminalReview(
                projectID: projectID, proposalID: proposalID, verdict: verdict
            )
        }
        func recordTerminalReviews(
            projectID: UUID, reviews: [WorkStateTransitionTerminalReview]
        ) async throws -> WorkStateTransitionReviewWriteResult {
            try await base.recordTerminalReviews(projectID: projectID, reviews: reviews)
        }
        func resolveAmbiguity(
            projectID: UUID, groupID: UUID,
            selection: WorkStateAmbiguousMatchSelection, reviewedAt: Date
        ) async throws -> WorkStateTransitionReviewWriteResult {
            try await base.resolveAmbiguity(
                projectID: projectID, groupID: groupID, selection: selection, reviewedAt: reviewedAt
            )
        }
        func pendingApplyIntents() async throws -> [WorkStateTransitionApplyIntent] {
            try await base.pendingApplyIntents()
        }
        func prepareApplyIntent(
            _ intent: WorkStateTransitionApplyIntent
        ) async throws -> WorkStateTransitionApplyIntentWriteResult {
            try await base.prepareApplyIntent(intent)
        }
        func finalizeApplyIntent(
            _ intent: WorkStateTransitionApplyIntent
        ) async throws -> WorkStateTransitionReviewWriteResult {
            try await base.finalizeApplyIntent(intent)
        }
        func recordMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws {
            try await base.recordMeetingDeletionIntent(intent)
        }
        func pendingMeetingDeletionIntents() async throws -> [MeetingDeletionIntent] {
            try await base.pendingMeetingDeletionIntents()
        }
        func applyMeetingDeletion(_ intent: MeetingDeletionIntent) async throws {
            try await base.applyMeetingDeletion(intent)
        }
        func clearMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws {
            try await base.clearMeetingDeletionIntent(intent)
        }
    }

    /// Two projects whose sidecars are deliberately indistinguishable except for `projectID` —
    /// same object UUID, same meeting id, same shapes. Anything that leaks across is a scope bug,
    /// and it will show up as the other project's rows changing.
    private func makeProjectDeletionFixture(
        meetings: Int = 1
    ) async throws -> (
        repository: InMemoryProjectRepository,
        transitions: InMemoryWorkStateTransitionRepository,
        service: ProjectDeletionService,
        sharedObjectID: UUID,
        sharedMeetingID: UUID,
        targetGroupID: UUID,
        otherGroupID: UUID
    ) {
        let repository = InMemoryProjectRepository()
        let sharedObjectID = UUID(uuidString: "D1000000-0000-4000-8000-000000000001")!
        let sharedMeetingID = UUID(uuidString: "D1000000-0000-4000-8000-000000000002")!
        let meeting = makeMeeting(
            id: sharedMeetingID, projectID: TestFixtures.projectID, title: "Target"
        )
        try await repository.save(makeProject(
            id: TestFixtures.projectID,
            meetings: meetings == 0 ? [] : [meeting]
        ))
        try await repository.save(makeProject(id: Self.otherProjectID, meetings: []))

        func rows(for projectID: UUID) -> (
            WorkStateTransitionProposal, WorkStateAmbiguousMatchGroup, WorkStateTransitionRefusalRecord
        ) {
            (
                makeProposal(
                    projectID: projectID,
                    sourceMeetingID: sharedMeetingID,
                    currentObjectID: sharedObjectID,
                    reviewStatus: .approved
                ),
                makeAmbiguityGroup(
                    projectID: projectID,
                    sourceMeetingID: sharedMeetingID,
                    incomingObjectID: sharedObjectID,
                    priorCandidateIDs: [sharedObjectID]
                ),
                makeRefusal(
                    projectID: projectID,
                    sourceMeetingID: sharedMeetingID,
                    currentObjectID: sharedObjectID,
                    reason: .missingEvidence
                )
            )
        }
        let target = rows(for: TestFixtures.projectID)
        let other = rows(for: Self.otherProjectID)

        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: [target.0, other.0],
            ambiguousMatchGroups: [target.1, other.1],
            ambiguityReviews: [
                makeAmbiguityReview(group: target.1), makeAmbiguityReview(group: other.1)
            ],
            refusals: [target.2, other.2]
        )
        for projectID in [TestFixtures.projectID, Self.otherProjectID] {
            let group = projectID == TestFixtures.projectID ? target.1 : other.1
            _ = try await transitions.prepareApplyIntent(
                WorkStateTransitionApplyIntent.ambiguity(
                    projectID: projectID,
                    groupID: group.id,
                    selection: .new,
                    reviewedAt: TestFixtures.fixedDate
                )
            )
            try await transitions.recordMeetingDeletionIntent(
                MeetingDeletionIntent(
                    projectID: projectID,
                    meetingID: sharedMeetingID,
                    removedWorkStateIDs: [sharedObjectID],
                    requestedAt: TestFixtures.fixedDate
                )
            )
        }

        let service = ProjectDeletionService(
            repository: repository,
            transitions: transitions,
            now: { TestFixtures.laterDate }
        )
        return (
            repository, transitions, service,
            sharedObjectID, sharedMeetingID, target.1.id, other.1.id
        )
    }

    /// Everything the other project holds, as one comparable value.
    private func otherProjectRows(
        _ transitions: InMemoryWorkStateTransitionRepository,
        groupID: UUID
    ) async throws -> (
        [WorkStateTransitionProposal], [WorkStateAmbiguousMatchGroup],
        [WorkStateTransitionRefusalRecord], WorkStateAmbiguityReviewState?,
        [WorkStateTransitionApplyIntent], [MeetingDeletionIntent]
    ) {
        (
            try await transitions.proposals(forProject: Self.otherProjectID),
            try await transitions.ambiguousMatchGroups(forProject: Self.otherProjectID),
            try await transitions.refusals(forProject: Self.otherProjectID),
            try await transitions.ambiguityReview(groupID: groupID),
            try await transitions.pendingApplyIntents().filter { $0.projectID == Self.otherProjectID },
            try await transitions.pendingMeetingDeletionIntents().filter { $0.projectID == Self.otherProjectID }
        )
    }

    func testDeletingAProjectRemovesEverySidecarKindItOwns() async throws {
        let f = try await makeProjectDeletionFixture()
        try await f.service.deleteProject(id: TestFixtures.projectID)

        let proposals = try await f.transitions.proposals(forProject: TestFixtures.projectID)
        let groups = try await f.transitions.ambiguousMatchGroups(forProject: TestFixtures.projectID)
        let refusals = try await f.transitions.refusals(forProject: TestFixtures.projectID)
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(groups.isEmpty)
        XCTAssertTrue(refusals.isEmpty)
    }

    /// The two collections with no `projectID` route of their own: a proposal's review is keyed by
    /// its dedupKey, and an ambiguity review by its group id.
    func testDeletingAProjectRemovesIndirectlyLinkedReviews() async throws {
        let f = try await makeProjectDeletionFixture()
        let reviewBefore = try await f.transitions.ambiguityReview(groupID: f.targetGroupID)
        XCTAssertNotNil(reviewBefore)

        try await f.service.deleteProject(id: TestFixtures.projectID)

        let reviewAfter = try await f.transitions.ambiguityReview(groupID: f.targetGroupID)
        XCTAssertNil(reviewAfter)
        // A proposal review outliving its proposal would come back as a pending row here.
        let proposals = try await f.transitions.allProposals()
        XCTAssertTrue(proposals.allSatisfy { $0.projectID != TestFixtures.projectID })
    }

    func testDeletingAProjectRemovesItsApplyAndMeetingDeletionIntents() async throws {
        let f = try await makeProjectDeletionFixture()
        try await f.service.deleteProject(id: TestFixtures.projectID)

        let applyIntents = try await f.transitions.pendingApplyIntents()
        let meetingIntents = try await f.transitions.pendingMeetingDeletionIntents()
        XCTAssertFalse(applyIntents.contains { $0.projectID == TestFixtures.projectID })
        XCTAssertFalse(meetingIntents.contains { $0.projectID == TestFixtures.projectID })
        let projectIntents = try await f.transitions.pendingProjectDeletionIntents()
        XCTAssertTrue(projectIntents.isEmpty, "the receipt retires in the same write as the rows")
    }

    /// The case a per-meeting intent could never express: nothing to iterate, rows still there.
    func testDeletingAProjectWithNoMeetingsStillCleansItsSidecar() async throws {
        let f = try await makeProjectDeletionFixture(meetings: 0)
        let loaded = try await f.repository.project(id: TestFixtures.projectID)
        let project = try XCTUnwrap(loaded)
        XCTAssertTrue(project.meetings.isEmpty)

        try await f.service.deleteProject(id: TestFixtures.projectID)

        let proposals = try await f.transitions.proposals(forProject: TestFixtures.projectID)
        let refusals = try await f.transitions.refusals(forProject: TestFixtures.projectID)
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(refusals.isEmpty)
    }

    /// The scoping guard. Every row here mirrors a deleted one and shares its object UUID, its
    /// meeting id and its shape; only `projectID` differs.
    func testDeletingAProjectLeavesAnotherProjectsRowsByteForByte() async throws {
        let f = try await makeProjectDeletionFixture()
        let before = try await otherProjectRows(f.transitions, groupID: f.otherGroupID)
        XCTAssertFalse(before.0.isEmpty)
        XCTAssertNotNil(before.3)

        try await f.service.deleteProject(id: TestFixtures.projectID)

        let after = try await otherProjectRows(f.transitions, groupID: f.otherGroupID)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
        XCTAssertEqual(after.3, before.3)
        XCTAssertEqual(after.4, before.4)
        XCTAssertEqual(after.5, before.5)
    }

    /// Stated separately from the row comparison above because it is the specific confusion worth
    /// ruling out: the shared id is never what selects a row.
    func testDeletingAProjectDoesNotFollowAnObjectUUIDIntoAnotherProject() async throws {
        let f = try await makeProjectDeletionFixture()
        try await f.service.deleteProject(id: TestFixtures.projectID)

        let survivors = try await f.transitions.proposals(forProject: Self.otherProjectID)
        XCTAssertTrue(survivors.contains { $0.currentObjectID == f.sharedObjectID })
    }

    func testDeletingAProjectWithoutContinuityConfiguredStillDeletesTheAggregate() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: []))
        let service = ProjectDeletionService(repository: repository, now: { TestFixtures.laterDate })

        try await service.deleteProject(id: TestFixtures.projectID)

        let loaded = try await repository.project(id: TestFixtures.projectID)
        XCTAssertNil(loaded)
    }

    /// The intent is written first, so a failure to remove the aggregate must leave the sidecar
    /// untouched and the receipt on disk for the next launch.
    func testAggregateDeleteFailureLeavesTheSidecarIntactAndTheIntentPending() async throws {
        let stored = makeProject(id: TestFixtures.projectID, meetings: [])
        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: [makeProposal(projectID: TestFixtures.projectID, sourceMeetingID: UUID())]
        )
        let service = ProjectDeletionService(
            repository: FailingProjectRepository(failureMode: .delete, stored: stored),
            transitions: transitions,
            now: { TestFixtures.laterDate }
        )

        do {
            try await service.deleteProject(id: TestFixtures.projectID)
            XCTFail("a failed aggregate delete must not report success")
        } catch {
            XCTAssertEqual(error as? ProjectDeletionError, .repositoryFailure)
        }

        let proposals = try await transitions.proposals(forProject: TestFixtures.projectID)
        XCTAssertEqual(proposals.count, 1, "the sweep must not run before the aggregate is gone")
        let pending = try await transitions.pendingProjectDeletionIntents()
        XCTAssertEqual(pending.count, 1)
    }

    /// The other side of the window: the aggregate is gone, the sweep failed. The receipt has to
    /// survive or those rows are orphaned for good.
    func testSidecarFailureAfterAggregateDeleteKeepsTheIntentForRecovery() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: []))
        let base = InMemoryWorkStateTransitionRepository(
            proposals: [makeProposal(projectID: TestFixtures.projectID, sourceMeetingID: UUID())]
        )
        let service = ProjectDeletionService(
            repository: repository,
            transitions: SidecarFailingOnProjectSweep(base: base),
            now: { TestFixtures.laterDate }
        )

        do {
            try await service.deleteProject(id: TestFixtures.projectID)
            XCTFail("a failed sidecar sweep must be reported")
        } catch {
            XCTAssertEqual(error as? ProjectDeletionError, .repositoryFailure)
        }

        let deletedProject = try await repository.project(id: TestFixtures.projectID)
        XCTAssertNil(deletedProject)
        let pending = try await base.pendingProjectDeletionIntents()
        XCTAssertEqual(pending.count, 1, "without the receipt those rows are orphaned for good")
    }

    /// In-memory convergence only. Process-level crash points are TM 1.5.
    func testRepeatedProjectDeletionRecoveryConvergesAndChangesNothingTwice() async throws {
        let f = try await makeProjectDeletionFixture()
        try await f.transitions.recordProjectDeletionIntent(
            ProjectDeletionIntent(projectID: TestFixtures.projectID, requestedAt: TestFixtures.fixedDate)
        )

        await f.service.recoverInterruptedProjectDeletions()
        let afterFirst = try await otherProjectRows(f.transitions, groupID: f.otherGroupID)
        let targetAfterFirst = try await f.transitions.proposals(forProject: TestFixtures.projectID)
        XCTAssertTrue(targetAfterFirst.isEmpty)
        let intentsAfterFirst = try await f.transitions.pendingProjectDeletionIntents()
        XCTAssertTrue(intentsAfterFirst.isEmpty)

        await f.service.recoverInterruptedProjectDeletions()
        let afterSecond = try await otherProjectRows(f.transitions, groupID: f.otherGroupID)
        XCTAssertEqual(afterSecond.0, afterFirst.0)
        XCTAssertEqual(afterSecond.3, afterFirst.3)
        let targetAfterSecond = try await f.transitions.proposals(forProject: TestFixtures.projectID)
        XCTAssertTrue(targetAfterSecond.isEmpty)
    }

    func testASidecarWithoutTheProjectDeletionIntentFieldStillDecodes() throws {
        let json = Data("""
        {"schemaVersion":4,"proposals":[],"reviews":[],"ambiguousMatchGroups":[],        "ambiguityReviews":[],"refusals":[],"applyIntents":[],"meetingDeletionIntents":[]}
        """.utf8)

        let decoded = try JSONDecoder().decode(WorkStateTransitionStoreFile.self, from: json)

        XCTAssertTrue(decoded.projectDeletionIntents.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, 4, "an additive optional field is not a new schema")
    }

    /// A project deletion receipt has two fields and can have no more — no title, no meeting, no
    /// Work State text. The deletion is removing exactly that content.
    func testProjectDeletionIntentSerializesIdentifiersAndATimestampOnly() throws {
        let intent = ProjectDeletionIntent(
            projectID: TestFixtures.projectID, requestedAt: TestFixtures.fixedDate
        )
        let encoded = try JSONEncoder().encode(intent)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["projectID", "requestedAt"])
    }

    /// Audio goes last, after both stores. Proven by the failure path: when the sidecar sweep
    /// throws, the aggregate is already gone but the file is still on disk.
    func testAudioIsUnlinkedOnlyAfterTheAggregateAndSidecarAreDone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENAProjectDeletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetStore = AudioAssetStore(directoryURL: directory)

        var meeting = makeMeeting(projectID: TestFixtures.projectID, title: "With audio")
        let asset = AudioAsset(
            id: UUID(),
            storedFileName: "recording.m4a",
            originalFileName: "recording.m4a",
            byteSize: 4,
            importedAt: TestFixtures.fixedDate
        )
        meeting.audioAsset = asset
        let fileURL = assetStore.url(for: asset)
        try Data([0, 1, 2, 3]).write(to: fileURL)

        let repository = InMemoryProjectRepository()
        try await repository.save(makeProject(id: TestFixtures.projectID, meetings: [meeting]))
        let base = InMemoryWorkStateTransitionRepository()
        let service = ProjectDeletionService(
            repository: repository,
            assetStore: assetStore,
            transitions: SidecarFailingOnProjectSweep(base: base),
            now: { TestFixtures.laterDate }
        )

        _ = try? await service.deleteProject(id: TestFixtures.projectID)

        let deletedProject = try await repository.project(id: TestFixtures.projectID)
        XCTAssertNil(deletedProject)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "audio must not be unlinked while the sidecar half is unfinished"
        )
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
