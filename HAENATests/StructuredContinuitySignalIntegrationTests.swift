import XCTest
@testable import HAENA

final class StructuredContinuitySignalIntegrationTests: XCTestCase {
    private struct TransitionStoreUnavailable: Error {}

    private struct MutatingExtractor: WorkStateExtractor {
        let repository: any ProjectRepository
        let projectID: UUID
        let result: WorkStateExtractionResult

        func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
            let loadedProject = try await repository.project(id: projectID)
            var project = try XCTUnwrap(loadedProject)
            // Simulates a user changing approval while the provider request is in flight.
            project.openQuestions[0].reviewedAt = nil
            try await repository.save(project)
            return result
        }
    }

    func testValidatedProgressSignalReachesEngineAndTransitionStoreAfterProjectSave() async throws {
        let meeting = ExtractionFixtures.meeting()
        var project = ExtractionFixtures.project(with: [meeting])
        project.actionItems = [approvedAction(title: "지표 정의 초안 작성", projectID: project.id)]

        let projects = InMemoryProjectRepository()
        try await projects.save(project)
        let transitions = InMemoryWorkStateTransitionRepository()
        let result = WorkStateExtractionResult(
            actionItems: ExtractionFixtures.fullResult().actionItems,
            progressSignals: [
                ProposedProgressSignal(
                    kind: .completed,
                    targetType: .incomingActionItem,
                    targetReference: "action_1",
                    evidence: ExtractionFixtures.evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )
        let service = WorkStateExtractionService(
            repository: projects,
            extractor: StubWorkStateExtractor(.success(result)),
            continuity: WorkStateContinuityService(
                projects: projects,
                transitions: transitions,
                now: { TestFixtures.laterDate }
            ),
            now: { TestFixtures.laterDate }
        )

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: project.id)

        XCTAssertEqual(report.acceptedProgressSignals, 1)
        XCTAssertEqual(report.transitionPersistenceStatus, .persisted)
        let loadedProject = try await projects.project(id: project.id)
        let savedProject = try XCTUnwrap(loadedProject)
        XCTAssertEqual(savedProject.actionItems.filter { $0.meetingID == meeting.id }.count, 1)
        let proposals = await transitions.proposals(forProject: project.id)
        XCTAssertTrue(proposals.contains { $0.transitionKind == .completed })
    }

    func testTransitionStoreFailureDoesNotRollbackAcceptedBaseWorkState() async throws {
        let meeting = ExtractionFixtures.meeting()
        let projects = InMemoryProjectRepository()
        try await projects.save(ExtractionFixtures.project(with: [meeting]))
        let transitions = InMemoryWorkStateTransitionRepository(
            saveError: TransitionStoreUnavailable()
        )
        let service = WorkStateExtractionService(
            repository: projects,
            extractor: StubWorkStateExtractor(.success(ExtractionFixtures.fullResult())),
            continuity: WorkStateContinuityService(projects: projects, transitions: transitions),
            now: { TestFixtures.laterDate }
        )

        let report = try await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )

        XCTAssertEqual(report.transitionPersistenceStatus, .failed)
        XCTAssertEqual(report.storedCount, 4)
        let loadedProject = try await projects.project(id: meeting.projectID)
        let saved = try XCTUnwrap(loadedProject)
        XCTAssertEqual(saved.decisions.count, 1)
        XCTAssertEqual(saved.actionItems.count, 1)
        XCTAssertEqual(saved.openQuestions.count, 1)
        XCTAssertEqual(saved.nextAgenda.count, 1)
        let proposals = await transitions.allProposals()
        XCTAssertTrue(proposals.isEmpty)
    }

    func testPriorStateChangedDuringProviderCallRejectsOnlyStaleSignal() async throws {
        let meeting = ExtractionFixtures.meeting()
        var project = ExtractionFixtures.project(with: [meeting])
        let priorQuestion = approvedQuestion(projectID: project.id)
        project.openQuestions = [priorQuestion]
        let projects = InMemoryProjectRepository()
        try await projects.save(project)
        let transitions = InMemoryWorkStateTransitionRepository()
        let result = WorkStateExtractionResult(
            decisions: ExtractionFixtures.fullResult().decisions,
            openQuestionResolutionLinks: [
                ProposedOpenQuestionResolutionLink(
                    priorOpenQuestionReference: "prior_question_1",
                    targetKind: .decision,
                    targetProviderLocalKey: "decision_1",
                    evidence: ExtractionFixtures.evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )
        let service = WorkStateExtractionService(
            repository: projects,
            extractor: MutatingExtractor(repository: projects, projectID: project.id, result: result),
            continuity: WorkStateContinuityService(projects: projects, transitions: transitions),
            now: { TestFixtures.laterDate }
        )

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: project.id)

        XCTAssertEqual(report.storedDecisions, 1)
        XCTAssertEqual(report.acceptedOpenQuestionResolutionLinks, 0)
        XCTAssertEqual(
            report.rejectedSignals,
            [RejectedContinuitySignal(kind: .openQuestionResolution, reason: .stalePriorState)]
        )
        XCTAssertEqual(report.transitionPersistenceStatus, .persisted)
        let loadedProject = try await projects.project(id: project.id)
        let saved = try XCTUnwrap(loadedProject)
        XCTAssertEqual(saved.decisions.count, 1, "stale sidecar must not discard accepted base state")
        XCTAssertNil(saved.openQuestions[0].reviewedAt)
        let proposals = await transitions.proposals(forProject: project.id)
        XCTAssertFalse(proposals.contains { $0.transitionKind == .resolved })
    }

    private func approvedAction(title: String, projectID: UUID) -> ActionItem {
        ActionItem(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            projectID: projectID,
            meetingID: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
            title: title,
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .confirmed,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func approvedQuestion(projectID: UUID) -> OpenQuestion {
        OpenQuestion(
            id: UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!,
            projectID: projectID,
            meetingID: UUID(uuidString: "A2000000-0000-4000-8000-000000000002")!,
            question: "지표 정의는 누가 확정하는가?",
            status: .open,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            resolvedAt: nil,
            reviewedAt: TestFixtures.fixedDate
        )
    }
}
