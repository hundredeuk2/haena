import XCTest
@testable import HAENA

private let reviewTestPointer = TransitionEvidencePointer(
    meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
    transcriptSegmentID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
)

final class WorkStateTransitionReviewServiceTests: XCTestCase {
    private static let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testPendingAgendaNewApprovalMarksItReviewed() async throws {
        var project = makeProject()
        project.nextAgenda = [agenda(20)]
        let row = proposal(kind: .agendaItem, transition: .new, currentID: id(20))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])
        let service = service(projects, transitions)

        let result = await service.review(projectID: project.id, proposalID: row.id, action: .approve)
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.nextAgenda.first?.reviewedAt, Self.reviewedAt)
        let stored = try await transitions.allProposals()
        XCTAssertEqual(stored.first?.reviewStatus, .approved)
    }

    func testSameApprovalKeepsCanonicalPriorAndRemovesCurrentDuplicate() async throws {
        var project = makeProject()
        project.decisions = [decision(1, approved: true), decision(2)]
        let row = proposal(kind: .decision, transition: .same, previousID: id(1), currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.decisions.map(\.id), [id(1)])
        XCTAssertEqual(saved.decisions.first?.createdAt, Self.createdAt)
    }

    func testChangedActionPreservesCanonicalIdentityAndCopiesSupportedFields() async throws {
        var project = makeProject()
        let existingReminder = ActionItemReminder(
            id: id(90),
            projectID: project.id,
            actionItemID: id(1),
            fireAt: Self.reviewedAt,
            status: .scheduled,
            createdAt: Self.createdAt,
            updatedAt: Self.createdAt,
            cancellationReason: nil
        )
        let provenance = AssigneeAttribution(
            basis: .speakerCommitment,
            reference: nil,
            speakerLabel: "SPEAKER_01",
            resolution: .resolved
        )
        project.actionItems = [action(1, approved: true), action(2, title: "new title", provenance: provenance)]
        let row = proposal(kind: .actionItem, transition: .changed, previousID: id(1), currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.actionItems.count, 1)
        XCTAssertEqual(saved.actionItems[0].id, id(1))
        XCTAssertEqual(saved.actionItems[0].id, existingReminder.actionItemID)
        XCTAssertEqual(
            ActionItemReminder.notificationIdentifier(for: saved.actionItems[0].id),
            existingReminder.notificationIdentifier
        )
        XCTAssertEqual(saved.actionItems[0].createdAt, Self.createdAt)
        XCTAssertEqual(saved.actionItems[0].title, "new title")
        XCTAssertEqual(saved.actionItems[0].proposedAssigneeAttribution, provenance)
        XCTAssertEqual(saved.actionItems[0].status, .confirmed)
    }

    func testCompletedApprovalCompletesPriorAndAtomicallyTerminatesPairedSame() async throws {
        var project = makeProject()
        project.actionItems = [action(1, approved: true), action(2)]
        let same = proposal(kind: .actionItem, transition: .same, previousID: id(1), currentID: id(2))
        let completed = proposal(
            kind: .actionItem,
            transition: .completed,
            previousID: id(1),
            currentID: id(2),
            basis: .structuredProgressSignal
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [same, completed])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: completed.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.actionItems.map(\.id), [id(1)])
        XCTAssertEqual(saved.actionItems.first?.status, .completed)
        let stored = try await transitions.allProposals()
        XCTAssertEqual(stored.first(where: { $0.id == completed.id })?.reviewStatus, .approved)
        XCTAssertEqual(stored.first(where: { $0.id == same.id })?.reviewStatus, .rejected)
    }

    /// A prior-target proposal has no current duplicate by construction. Treating that absence as a
    /// stale proposal would leave the whole "the meeting only reported on old work" path
    /// permanently unapprovable.
    func testPriorTargetCompletedApprovalCompletesPriorWithoutAnyCurrentDuplicate() async throws {
        var project = makeProject()
        project.actionItems = [action(1, approved: true)]
        let completed = proposal(
            kind: .actionItem, transition: .completed,
            previousID: id(1), currentID: nil,
            basis: .structuredProgressSignal
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [completed])
        let reviewService = service(projects, transitions)

        let result = await reviewService.review(
            projectID: project.id, proposalID: completed.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.actionItems.map(\.id), [id(1)], "canonical identity survives")
        XCTAssertEqual(saved.actionItems.first?.status, .completed)

        let repeated = await reviewService.review(
            projectID: project.id, proposalID: completed.id, action: .approve
        )
        XCTAssertEqual(repeated, .alreadyApplied, "re-approving the same verdict is idempotent")
    }

    func testPriorTargetDelayApprovalLeavesStatusAndDueDateUntouched() async throws {
        for disposition in [WorkStateTransitionProgressDisposition.deferred, .blocked] {
            var project = makeProject()
            project.actionItems = [action(1, approved: true, dueDate: Self.createdAt)]
            let delayed = proposal(
                kind: .actionItem, transition: .delayed,
                previousID: id(1), currentID: nil,
                basis: .structuredProgressSignal,
                disposition: disposition
            )
            let projects = InMemoryProjectRepository(projects: [project])
            let transitions = InMemoryWorkStateTransitionRepository(proposals: [delayed])

            let result = await service(projects, transitions).review(
                projectID: project.id, proposalID: delayed.id, action: .approve
            )
            XCTAssertEqual(result, .applied, "\(disposition)")
            let loaded = try await projects.project(id: project.id)
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.actionItems.map(\.id), [id(1)], "\(disposition)")
            XCTAssertEqual(saved.actionItems.first?.status, .confirmed, "\(disposition): a delay is not a status change")
            XCTAssertEqual(saved.actionItems.first?.dueDate, Self.createdAt, "\(disposition): a delay never moves a date")
        }
    }

    func testResolutionApprovesQuestionAndDecisionTargetAndTerminatesTargetNew() async throws {
        var project = makeProject()
        project.openQuestions = [question(1, approved: true)]
        project.decisions = [decision(2)]
        let targetNew = proposal(kind: .decision, transition: .new, currentID: id(2))
        let resolved = proposal(
            kind: .openQuestion,
            transition: .resolved,
            previousID: id(1),
            currentID: id(2),
            basis: .structuredResolutionLink,
            relations: [.init(kind: .resolvedBy, relatedKind: .decision, relatedObjectID: id(2))]
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [targetNew, resolved])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: resolved.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let loaded = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.openQuestions.first?.status, .resolved)
        XCTAssertEqual(saved.decisions.first?.status, .confirmed)
        let stored = try await transitions.allProposals()
        XCTAssertEqual(stored.first(where: { $0.id == resolved.id })?.reviewStatus, .approved)
        XCTAssertEqual(stored.first(where: { $0.id == targetNew.id })?.reviewStatus, .approved)
    }

    func testRejectPersistsVerdictWithoutProjectMutation() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let original = project
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .reject
        )
        XCTAssertEqual(result, .rejected)
        let saved = try await projects.project(id: project.id)
        let stored = try await transitions.allProposals()
        XCTAssertEqual(saved, original)
        XCTAssertEqual(stored.first?.reviewStatus, .rejected)
    }

    func testStalePriorAndEmbeddedForeignCurrentAreFiniteRefusals() async throws {
        var stale = makeProject()
        stale.decisions = [decision(1, approved: false), decision(2)]
        let row = proposal(kind: .decision, transition: .same, previousID: id(1), currentID: id(2))
        let staleProjects = InMemoryProjectRepository(projects: [stale])
        let staleTransitions = InMemoryWorkStateTransitionRepository(proposals: [row])
        let staleResult = await service(staleProjects, staleTransitions).review(
            projectID: stale.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(staleResult, .refused(.staleProposal))

        var foreign = makeProject()
        foreign.decisions = [decision(1, approved: true), decision(2, projectID: id(999))]
        let foreignProjects = InMemoryProjectRepository(projects: [foreign])
        let foreignTransitions = InMemoryWorkStateTransitionRepository(proposals: [row])
        let foreignResult = await service(foreignProjects, foreignTransitions).review(
            projectID: foreign.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(foreignResult, .refused(.crossProjectObject))
    }

    func testCurrentEvidencePrecedesValidPointerAndDanglingQuoteBlocksApply() async throws {
        var project = makeProject()
        project.decisions = [decision(2, quote: "not present")]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(result, .refused(.evidenceNoLongerExists))
        let stored = try await transitions.allProposals()
        XCTAssertEqual(stored.first?.reviewStatus, .pendingReview)
    }

    func testOverdueApprovalNeedsNoTranscriptEvidence() async throws {
        var project = makeProject(transcriptText: nil)
        project.actionItems = [action(1, approved: true, dueDate: Self.createdAt.addingTimeInterval(-100))]
        let row = proposal(
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            currentID: nil,
            basis: .overdueApprovedDueDate,
            evidence: nil
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(result, .applied)
        let stored = try await transitions.allProposals()
        XCTAssertEqual(stored.first?.reviewStatus, .approved)
    }

    func testProjectSaveFailureLeavesReviewPending() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = FailingProjectRepository(project: project)
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(result, .refused(.projectPersistenceFailed))
        let stored = try await transitions.allProposals()
        let pendingIntents = try await transitions.pendingApplyIntents()
        XCTAssertEqual(stored.first?.reviewStatus, .pendingReview)
        XCTAssertEqual(pendingIntents.count, 1, "durable intent remains available for launch recovery")
    }

    func testIntentSaveFailureDoesNotMutateProject() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let original = project
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let base = InMemoryWorkStateTransitionRepository(proposals: [row])
        let transitions = FailOnceTransitionRepository(base: base, failurePoint: .prepare)

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        let saved = try await projects.project(id: project.id)
        let pendingIntents = try await base.pendingApplyIntents()
        XCTAssertEqual(result, .refused(.reviewPersistenceFailed))
        XCTAssertEqual(saved, original)
        XCTAssertTrue(pendingIntents.isEmpty)
    }

    func testReviewWriteFailureReturnsPartialAndSameServiceRetryIsSafe() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let base = InMemoryWorkStateTransitionRepository(proposals: [row])
        let transitions = FailOnceTransitionRepository(base: base)
        let reviewer = service(projects, transitions)

        let first = await reviewer.review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(first, .projectSavedReviewPersistenceFailed)
        let afterPartial = try await projects.project(id: project.id)
        XCTAssertEqual(afterPartial?.decisions.first?.status, .confirmed)
        let retry = await reviewer.review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        XCTAssertEqual(retry, .applied)
        let stored = try await base.allProposals()
        XCTAssertEqual(stored.first?.reviewStatus, .approved)
    }

    func testRestartAfterProjectMarkerBeforeVerdictFinalizesWithoutReapplyingProject() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-transition-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("projects.json")
        let transitionURL = directory.appendingPathComponent("continuity-transitions.json")
        var project = makeProject()
        project.decisions = [decision(2)]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = JSONProjectRepository(fileURL: projectURL)
        let transitionBase = JSONWorkStateTransitionRepository(fileURL: transitionURL)
        try await projects.save(project)
        try await transitionBase.upsert([row])
        let failFinalWrite = FailOnceTransitionRepository(base: transitionBase)

        let first = await service(projects, failFinalWrite).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        let afterFirstProject = try await projects.project(id: project.id)
        let afterFirstIntents = try await transitionBase.pendingApplyIntents()
        XCTAssertEqual(first, .projectSavedReviewPersistenceFailed)
        XCTAssertEqual(afterFirstProject?.decisions.count, 1)
        XCTAssertEqual(afterFirstIntents.count, 1)

        let restartedProjects = JSONProjectRepository(fileURL: projectURL)
        let restartedTransitions = JSONWorkStateTransitionRepository(fileURL: transitionURL)
        let outcomes = await service(restartedProjects, restartedTransitions).recoverPendingApplies()
        let recoveredProject = try await restartedProjects.project(id: project.id)
        let remainingIntents = try await restartedTransitions.pendingApplyIntents()
        let recoveredProposals = try await restartedTransitions.allProposals()

        XCTAssertEqual(outcomes.map(\.result), [.applied])
        XCTAssertEqual(recoveredProject?.decisions.count, 1)
        XCTAssertTrue(remainingIntents.isEmpty)
        XCTAssertEqual(recoveredProposals.first?.reviewStatus, .approved)
    }

    func testRestartAfterDurableIntentBeforeProjectSaveAppliesExactlyOnce() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])
        let intent = WorkStateTransitionApplyIntent.proposal(
            projectID: project.id,
            proposalID: row.id,
            terminalReviews: [.init(proposalID: row.id, verdict: .approved)],
            reviewedAt: Self.reviewedAt
        )
        let prepared = try await transitions.prepareApplyIntent(intent)

        let reviewer = service(projects, transitions)
        let firstRecovery = await reviewer.recoverPendingApplies()
        let secondRecovery = await reviewer.recoverPendingApplies()
        let recovered = try await projects.project(id: project.id)
        XCTAssertEqual(prepared, .recorded)
        XCTAssertEqual(firstRecovery.map(\.result), [.applied])
        XCTAssertEqual(secondRecovery, [])
        XCTAssertEqual(recovered?.decisions.count, 1)
        XCTAssertEqual(recovered?.decisions.first?.status, .confirmed)
    }

    func testCorruptIntentHashProducesFiniteRecoveryRefusalWithoutProjectMutation() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let original = project
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let valid = WorkStateTransitionApplyIntent.proposal(
            projectID: project.id,
            proposalID: row.id,
            terminalReviews: [.init(proposalID: row.id, verdict: .approved)],
            reviewedAt: Self.reviewedAt
        )
        let corrupt = WorkStateTransitionApplyIntent(
            projectID: valid.projectID,
            operationID: valid.operationID,
            operationKind: valid.operationKind,
            terminalReviews: valid.terminalReviews,
            ambiguitySelectionKind: valid.ambiguitySelectionKind,
            selectedPriorStateID: valid.selectedPriorStateID,
            reviewedAt: valid.reviewedAt,
            payloadHash: "corrupt"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-corrupt-transition-intent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transitionURL = directory.appendingPathComponent("continuity-transitions.json")
        let store = WorkStateTransitionStoreFile(proposals: [row], applyIntents: [corrupt])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: transitionURL)
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = JSONWorkStateTransitionRepository(fileURL: transitionURL)

        let outcomes = await service(projects, transitions).recoverPendingApplies()
        let saved = try await projects.project(id: project.id)
        XCTAssertEqual(outcomes.map(\.result), [.refused(.staleProposal)])
        XCTAssertEqual(saved, original)
    }

    func testNoOpDelayPersistsMarkerWithoutChangingProjectTimestamp() async throws {
        var project = makeProject()
        project.actionItems = [action(1, approved: true, dueDate: Self.createdAt)]
        let row = proposal(
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            basis: .structuredProgressSignal,
            disposition: .blocked
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(proposals: [row])

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )
        let saved = try await projects.project(id: project.id)
        let marker = try await projects.transitionApplyMarker(
            projectID: project.id,
            operationID: row.id,
            operationKind: .proposal
        )
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(saved?.updatedAt, Self.createdAt)
        XCTAssertNotNil(marker)
    }

    func testAmbiguityCandidateAndNewRecoverAfterMarkerWithoutDuplicate() async throws {
        let selections: [WorkStateAmbiguousMatchSelection] = [.priorCandidate(id(1)), .new]
        for selection in selections {
            var project = makeProject()
            project.decisions = [decision(1, approved: true), decision(3, approved: true), decision(2)]
            let first = proposal(
                kind: .decision, transition: .changed, previousID: id(1), currentID: id(2)
            )
            let second = proposal(
                kind: .decision, transition: .changed, previousID: id(3), currentID: id(2)
            )
            let group = WorkStateAmbiguousMatchGroup(
                projectID: project.id,
                sourceMeetingID: id(101),
                workStateKind: .decision,
                incomingObjectID: id(2),
                priorCandidateIDs: [id(1), id(3)]
            )
            let projects = InMemoryProjectRepository(projects: [project])
            let base = InMemoryWorkStateTransitionRepository(
                proposals: [first, second], ambiguousMatchGroups: [group]
            )
            let failFinalWrite = FailOnceTransitionRepository(base: base)
            let firstResult = await service(projects, failFinalWrite).resolveAmbiguity(
                projectID: project.id, groupID: group.id, selection: selection
            )
            XCTAssertEqual(firstResult, .projectSavedReviewPersistenceFailed, "\(selection)")

            let recovery = await service(projects, base).recoverPendingApplies()
            let saved = try await projects.project(id: project.id)
            let review = try await base.ambiguityReview(groupID: group.id)
            let remainingIntents = try await base.pendingApplyIntents()
            XCTAssertEqual(recovery.map(\.result), [.applied], "\(selection)")
            XCTAssertTrue(remainingIntents.isEmpty, "\(selection)")
            XCTAssertEqual(review?.matches(selection), true, "\(selection)")
            XCTAssertEqual(Set(saved?.decisions.map(\.id) ?? []).count, saved?.decisions.count)
        }
    }

    func testFiniteReviewRaceAfterProjectSaveIsReportedAsPartialFailure() async throws {
        var project = makeProject()
        project.decisions = [decision(2)]
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let projects = InMemoryProjectRepository(projects: [project])
        let base = InMemoryWorkStateTransitionRepository(proposals: [row])
        let transitions = FailOnceTransitionRepository(base: base, mode: .finiteConflict)

        let result = await service(projects, transitions).review(
            projectID: project.id, proposalID: row.id, action: .approve
        )

        XCTAssertEqual(result, .projectSavedReviewPersistenceFailed)
        let saved = try await projects.project(id: project.id)
        XCTAssertEqual(saved?.decisions.first?.status, .confirmed)
        let stored = try await base.allProposals()
        XCTAssertEqual(stored.first?.reviewStatus, .pendingReview)
    }

    func testAmbiguityCandidateSelectionAppliesChosenCanonicalAndRejectsSibling() async throws {
        var project = makeProject()
        project.decisions = [
            decision(1, approved: true),
            decision(3, approved: true),
            decision(2)
        ]
        let first = proposal(
            kind: .decision, transition: .changed, previousID: id(1), currentID: id(2)
        )
        let second = proposal(
            kind: .decision, transition: .changed, previousID: id(3), currentID: id(2)
        )
        let group = WorkStateAmbiguousMatchGroup(
            projectID: id(100), sourceMeetingID: id(101), workStateKind: .decision,
            incomingObjectID: id(2), priorCandidateIDs: [id(1), id(3)]
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: [first, second], ambiguousMatchGroups: [group]
        )

        let result = await service(projects, transitions).resolveAmbiguity(
            projectID: project.id, groupID: group.id, selection: .priorCandidate(id(1))
        )

        XCTAssertEqual(result, .applied)
        let saved = try await projects.project(id: project.id)
        XCTAssertEqual(saved?.decisions.map(\.id), [id(1), id(3)])
        XCTAssertEqual(saved?.decisions.first(where: { $0.id == id(1) })?.statement, "D2")
        let rows = try await transitions.allProposals()
        XCTAssertEqual(rows.first(where: { $0.id == first.id })?.reviewStatus, .approved)
        XCTAssertEqual(rows.first(where: { $0.id == second.id })?.reviewStatus, .rejected)
    }

    func testAmbiguityNewSelectionApprovesIncomingAndRejectsAllCandidates() async throws {
        var project = makeProject()
        project.decisions = [
            decision(1, approved: true),
            decision(3, approved: true),
            decision(2)
        ]
        let first = proposal(
            kind: .decision, transition: .changed, previousID: id(1), currentID: id(2)
        )
        let second = proposal(
            kind: .decision, transition: .changed, previousID: id(3), currentID: id(2)
        )
        let group = WorkStateAmbiguousMatchGroup(
            projectID: id(100), sourceMeetingID: id(101), workStateKind: .decision,
            incomingObjectID: id(2), priorCandidateIDs: [id(1), id(3)]
        )
        let projects = InMemoryProjectRepository(projects: [project])
        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: [first, second], ambiguousMatchGroups: [group]
        )

        let result = await service(projects, transitions).resolveAmbiguity(
            projectID: project.id, groupID: group.id, selection: .new
        )

        XCTAssertEqual(result, .applied)
        let saved = try await projects.project(id: project.id)
        XCTAssertEqual(saved?.decisions.first(where: { $0.id == id(2) })?.status, .confirmed)
        let rows = try await transitions.allProposals()
        XCTAssertTrue(rows.allSatisfy { $0.reviewStatus == .rejected })
        let review = try await transitions.ambiguityReview(groupID: group.id)
        XCTAssertEqual(review?.selectionKind, .new)
        XCTAssertEqual(review?.reviewedAt, Self.reviewedAt)
    }

    func testJSONReviewSurvivesRepositoryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-review-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("continuity-transitions.json")
        let row = proposal(kind: .decision, transition: .new, currentID: id(2))
        let writer = JSONWorkStateTransitionRepository(fileURL: url)
        try await writer.upsert([row])
        let writeResult = try await writer.recordTerminalReview(
            projectID: id(100), proposalID: row.id, verdict: .approved
        )
        XCTAssertEqual(writeResult, .recorded)

        let reader = JSONWorkStateTransitionRepository(fileURL: url)
        let reloaded = try await reader.allProposals()
        XCTAssertEqual(reloaded.first?.reviewStatus, .approved)
    }

    // MARK: Fixtures

    private func service(
        _ projects: any WorkStateTransitionProjectRepository,
        _ transitions: any WorkStateTransitionRepository
    ) -> WorkStateTransitionReviewService {
        WorkStateTransitionReviewService(
            projectRepository: projects,
            transitionRepository: transitions,
            now: { Self.reviewedAt }
        )
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
    private func id(_ value: Int) -> UUID { Self.id(value) }

    private func makeProject(transcriptText: String? = "evidence quote") -> Project {
        let segment = transcriptText.map {
            TranscriptSegment(
                id: id(102), meetingID: id(101), speakerID: nil,
                text: $0, startTime: nil, endTime: nil
            )
        }
        return Project(
            id: id(100), name: "P", summary: "", createdAt: Self.createdAt,
            updatedAt: Self.createdAt,
            meetings: [Meeting(
                id: id(101), projectID: id(100), title: "M",
                occurredAt: Self.createdAt, sourceType: .pastedText,
                participants: [], transcriptSegments: segment.map { [$0] } ?? [],
                createdAt: Self.createdAt
            )],
            decisions: [], actionItems: [], openQuestions: [], nextAgenda: []
        )
    }

    private func evidence(quote: String = "evidence quote") -> EvidenceReference {
        EvidenceReference(meetingID: id(101), transcriptSegmentID: id(102), quote: quote)
    }

    private func decision(
        _ value: Int,
        approved: Bool = false,
        projectID: UUID? = nil,
        quote: String = "evidence quote"
    ) -> Decision {
        Decision(
            id: id(value), projectID: projectID ?? id(100), meetingID: id(101),
            statement: "D\(value)", rationale: nil,
            status: approved ? .confirmed : .proposed,
            evidence: evidence(quote: quote), confidence: .maximum,
            createdAt: Self.createdAt, updatedAt: Self.createdAt
        )
    }

    private func action(
        _ value: Int,
        approved: Bool = false,
        title: String? = nil,
        provenance: AssigneeAttribution? = nil,
        dueDate: Date? = nil
    ) -> ActionItem {
        ActionItem(
            id: id(value), projectID: id(100), meetingID: id(101),
            title: title ?? "A\(value)", details: nil, assigneeID: nil, dueDate: dueDate,
            status: approved ? .confirmed : .proposed,
            evidence: evidence(), confidence: .maximum,
            proposedAssigneeAttribution: provenance,
            createdAt: Self.createdAt, updatedAt: Self.createdAt
        )
    }

    private func question(_ value: Int, approved: Bool = false) -> OpenQuestion {
        OpenQuestion(
            id: id(value), projectID: id(100), meetingID: id(101),
            question: "Q\(value)", status: .open, evidence: evidence(), confidence: .maximum,
            createdAt: Self.createdAt, resolvedAt: nil,
            reviewedAt: approved ? Self.createdAt : nil
        )
    }

    private func agenda(_ value: Int) -> AgendaItem {
        AgendaItem(
            id: id(value), projectID: id(100), title: "G\(value)", reason: "R",
            sourceMeetingID: id(101), relatedActionItemID: nil, relatedOpenQuestionID: nil,
            status: .pending, createdAt: Self.createdAt,
            evidence: evidence(), confidence: .maximum, reviewedAt: nil
        )
    }

    private func proposal(
        kind: WorkStateKind,
        transition: WorkStateTransitionKind,
        previousID: UUID? = nil,
        currentID: UUID? = nil,
        basis: WorkStateTransitionBasis = .exactNormalizedTextMatch,
        disposition: WorkStateTransitionProgressDisposition? = nil,
        evidence: TransitionEvidencePointer? = reviewTestPointer,
        relations: [WorkStateTransitionRelation] = []
    ) -> WorkStateTransitionProposal {
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: id(100), workStateKind: kind, transitionKind: transition,
            previousStateID: previousID, currentObjectID: currentID
        )
        return WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
            projectID: id(100), workStateKind: kind, transitionKind: transition,
            previousStateID: previousID, currentObjectID: currentID,
            sourceMeetingID: id(101), evidence: evidence, basis: basis,
            progressDisposition: disposition, reasons: [], requiresConfirmation: true,
            relations: relations, dedupKey: key, createdAt: Self.createdAt
        )
    }
}

private enum ReviewTestError: Error { case forced }

private actor FailingProjectRepository: WorkStateTransitionProjectRepository {
    private let stored: Project
    init(project: Project) { stored = project }
    func save(_ project: Project) throws { throw ReviewTestError.forced }
    func save(
        _ project: Project,
        recording marker: WorkStateTransitionApplyMarker
    ) throws { throw ReviewTestError.forced }
    func transitionApplyMarker(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind
    ) -> WorkStateTransitionApplyMarker? { nil }
    func project(id: UUID) -> Project? { stored.id == id ? stored : nil }
    func allProjects() -> [Project] { [stored] }
    func delete(id: UUID) throws { throw ReviewTestError.forced }
}

private actor FailOnceTransitionRepository: WorkStateTransitionRepository {
    enum FailureMode { case throwing, finiteConflict }
    enum FailurePoint { case prepare, finalize }
    private let base: any WorkStateTransitionRepository
    private let mode: FailureMode
    private let failurePoint: FailurePoint
    private var shouldFail = true
    init(
        base: any WorkStateTransitionRepository,
        mode: FailureMode = .throwing,
        failurePoint: FailurePoint = .finalize
    ) {
        self.base = base
        self.mode = mode
        self.failurePoint = failurePoint
    }

    func proposals(forProject projectID: UUID) async throws -> [WorkStateTransitionProposal] {
        try await base.proposals(forProject: projectID)
    }
    func allProposals() async throws -> [WorkStateTransitionProposal] { try await base.allProposals() }
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
    func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) async throws {
        try await base.recordProjectDeletionIntent(intent)
    }
    func pendingProjectDeletionIntents() async throws -> [ProjectDeletionIntent] {
        try await base.pendingProjectDeletionIntents()
    }
    func applyProjectDeletion(_ intent: ProjectDeletionIntent) async throws {
        try await base.applyProjectDeletion(intent)
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
    func pendingApplyIntents() async throws -> [WorkStateTransitionApplyIntent] {
        try await base.pendingApplyIntents()
    }
    func prepareApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionApplyIntentWriteResult {
        if shouldFail && failurePoint == .prepare {
            shouldFail = false
            throw ReviewTestError.forced
        }
        return try await base.prepareApplyIntent(intent)
    }
    func finalizeApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionReviewWriteResult {
        if shouldFail && failurePoint == .finalize {
            shouldFail = false
            switch mode {
            case .throwing: throw ReviewTestError.forced
            case .finiteConflict: return .refused(.terminalVerdictConflict)
            }
        }
        return try await base.finalizeApplyIntent(intent)
    }
    func upsert(_ proposals: [WorkStateTransitionProposal]) async throws { try await base.upsert(proposals) }
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
        try await recordTerminalReviews(
            projectID: projectID,
            reviews: [.init(proposalID: proposalID, verdict: verdict)]
        )
    }
    func recordTerminalReviews(
        projectID: UUID, reviews: [WorkStateTransitionTerminalReview]
    ) async throws -> WorkStateTransitionReviewWriteResult {
        return try await base.recordTerminalReviews(projectID: projectID, reviews: reviews)
    }
    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) async throws -> WorkStateTransitionReviewWriteResult {
        try await base.resolveAmbiguity(
            projectID: projectID, groupID: groupID, selection: selection, reviewedAt: reviewedAt
        )
    }
}
