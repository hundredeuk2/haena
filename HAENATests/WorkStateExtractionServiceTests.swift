import XCTest
@testable import HAENA

final class WorkStateExtractionServiceTests: XCTestCase {
    private var meeting: Meeting!
    private var repository: InMemoryProjectRepository!

    override func setUp() async throws {
        meeting = ExtractionFixtures.meeting()
        repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: [meeting]))
    }

    private func makeService(
        _ outcome: StubWorkStateExtractor.Outcome,
        repository: (any ProjectRepository)? = nil
    ) -> WorkStateExtractionService {
        WorkStateExtractionService(
            repository: repository ?? self.repository,
            extractor: StubWorkStateExtractor(outcome),
            now: { TestFixtures.laterDate }
        )
    }

    private func storedProject(from repository: (any ProjectRepository)? = nil) async throws -> Project {
        let repository = repository ?? self.repository!
        let project = try await repository.project(id: TestFixtures.projectID)
        return try XCTUnwrap(project)
    }

    // MARK: - Applying results

    func testStoresAllFourKindsAgainstTheProject() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedDecisions, 1)
        XCTAssertEqual(report.storedActionItems, 1)
        XCTAssertEqual(report.storedOpenQuestions, 1)
        XCTAssertEqual(report.storedAgendaItems, 1)
        XCTAssertTrue(report.rejected.isEmpty)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
        XCTAssertEqual(project.openQuestions.count, 1)
        XCTAssertEqual(project.nextAgenda.count, 1)
        XCTAssertEqual(project.updatedAt, TestFixtures.laterDate)
    }

    func testEmptyExtractionStoresNothingAndLeavesTheMeetingIntact() async throws {
        let service = makeService(.success(ExtractionFixtures.emptyResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedCount, 0)
        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertTrue(project.nextAgenda.isEmpty)
        XCTAssertEqual(project.meetings.count, 1)
    }

    func testReportsRejectedProposalsWithoutStoringThem() async throws {
        let service = makeService(.success(
            ExtractionFixtures.fullResult(evidence: ExtractionFixtures.evidence(quote: "회의록에 없는 문장"))
        ))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedCount, 0)
        XCTAssertEqual(report.rejected.count, 4)
        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
    }

    func testCarriesProviderMetadataIntoTheReport() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.metadata.provider, .openAI)
        XCTAssertEqual(report.metadata.modelID, "test-model")
    }

    // MARK: - Credential boundary

    /// The product promise behind the credential split: a run that cannot get a key finishes, and
    /// finishes having touched nothing. The meeting the user already saved stays exactly as it was.
    func testACredentialThatNeedsInteractionLeavesTheMeetingAndChangesNothingElse() async throws {
        let before = try await storedProject()
        let service = makeService(.failure(.credentialInteractionRequired))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            XCTFail("expected the credential boundary to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .credentialInteractionRequired)
        }

        let after = try await storedProject()
        XCTAssertEqual(after.meetings.map(\.id), before.meetings.map(\.id))
        XCTAssertTrue(after.decisions.isEmpty)
        XCTAssertTrue(after.actionItems.isEmpty)
        XCTAssertTrue(after.openQuestions.isEmpty)
        XCTAssertTrue(after.nextAgenda.isEmpty)
    }

    func testACredentialThatNeedsInteractionStopsTheMarkersAtTheStartedBoundary() async throws {
        let probe = PhaseProbe()
        let service = makeService(.failure(.credentialInteractionRequired))

        _ = try? await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            phases: probe.recorder
        )

        let reached = try await probe.reachedPhases()
        XCTAssertEqual(reached, [.extractionStarted])
    }

    // MARK: - Phase instrumentation

    /// The markers exist to answer "how far did it get?" after a run that never reached the
    /// completion screen, so what matters is which boundaries a run reached — not the order the
    /// rows happened to land in, which is why every assertion sorts by the enum's own sequence.
    func testASuccessfulRunRecordsTheServiceSidePhasesInLogicalOrder() async throws {
        let probe = PhaseProbe()
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        _ = try await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            phases: probe.recorder
        )

        let reached = try await probe.reachedPhases()
        XCTAssertEqual(
            reached,
            [.extractionStarted, .providerReturned, .projectSaved, .transitionRecordReturned]
        )
    }

    func testAProviderThatNeverReturnsLeavesOnlyTheStartedPhase() async throws {
        let probe = PhaseProbe()
        let service = makeService(.failure(.rateLimited))

        do {
            _ = try await service.extractAndApply(
                meetingID: meeting.id,
                projectID: meeting.projectID,
                phases: probe.recorder
            )
            XCTFail("expected the provider error to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .rateLimited)
        }

        let reached = try await probe.reachedPhases()
        XCTAssertEqual(reached, [.extractionStarted])
    }

    func testAFailedProjectSaveStopsTheMarkersAtTheBoundaryItReached() async throws {
        let probe = PhaseProbe()
        let failing = PhaseFailingProjectRepository(
            stored: try await storedProject()
        )
        let service = makeService(.success(ExtractionFixtures.fullResult()), repository: failing)

        do {
            _ = try await service.extractAndApply(
                meetingID: meeting.id,
                projectID: meeting.projectID,
                phases: probe.recorder
            )
            XCTFail("expected the repository failure to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionServiceError, .repositoryFailure)
        }

        let reached = try await probe.reachedPhases()
        XCTAssertEqual(
            reached,
            [.extractionStarted, .providerReturned],
            "projectSaved must not be claimed for a save that threw"
        )
    }

    /// `transitionRecordReturned` says the continuity call came back finitely, which is a different
    /// fact from the transitions having been written. A run with no continuity store configured
    /// still passes that boundary.
    func testTheTransitionBoundaryIsRecordedEvenWhenNothingWasPersisted() async throws {
        let probe = PhaseProbe()
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            phases: probe.recorder
        )

        XCTAssertEqual(report.transitionPersistenceStatus, .notConfigured)
        let reached = try await probe.reachedPhases()
        XCTAssertTrue(reached.contains(.transitionRecordReturned))
    }

    /// The whole point of the detached recorder: instrumentation must not become the next place a
    /// run can fail or stall.
    func testAMetricsRepositoryFailureDoesNotStopTheExtractionFromCompleting() async throws {
        let recorder = ExtractionPhaseRecorder(
            runID: UUID(),
            projectID: meeting.projectID,
            meetingID: meeting.id,
            metrics: BetaMetricsService(repository: FailingBetaMetricsRepository()),
            elapsedMilliseconds: { 0 }
        )
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            phases: recorder
        )

        XCTAssertEqual(report.storedDecisions, 1)
        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
    }

    /// Summary numbers describe the beta, not this investigation. A phase row must never move a
    /// rate up or down.
    func testPhaseRowsAreExcludedFromEverySummaryFigure() async throws {
        let probe = PhaseProbe()
        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            phases: probe.recorder
        )
        _ = try await probe.reachedPhases()

        let store = try await probe.store.store()
        let summary = BetaMetricsSummary(store: store, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(summary.meetingsProcessed, 0)
        XCTAssertEqual(summary.reviewedProposals, 0)
        XCTAssertEqual(summary.durationSampleCount, 0)
        XCTAssertNil(summary.medianDurationMilliseconds)
    }

    // MARK: - Failure must not damage stored data

    func testProviderFailureLeavesTheSavedMeetingAndProjectUntouched() async throws {
        let service = makeService(.failure(.rateLimited))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            XCTFail("expected the provider error to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .rateLimited)
        }

        let project = try await storedProject()
        XCTAssertEqual(project.meetings.count, 1)
        XCTAssertEqual(project.meetings[0].transcriptSegments[0].text, ExtractionFixtures.transcript)
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate, "a failed extraction must not touch the project")
    }

    func testMissingCredentialSurfacesAsAnErrorRatherThanFabricatedResults() async throws {
        let service = makeService(.failure(.missingCredential))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            XCTFail("expected missingCredential to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .missingCredential)
        }

        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertTrue(project.actionItems.isEmpty)
    }

    func testUnknownProjectAndMeetingAreRejectedBeforeExtraction() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: UUID())
            XCTFail("expected projectNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionServiceError, .projectNotFound)
        }

        do {
            _ = try await service.extractAndApply(meetingID: UUID(), projectID: meeting.projectID)
            XCTFail("expected meetingNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionServiceError, .meetingNotFound)
        }
    }

    // MARK: - Re-extraction policy

    func testReExtractingReplacesPreviousProposalsInsteadOfAccumulating() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let first = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
        let second = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(first.replacedProposals, 0)
        XCTAssertEqual(second.replacedProposals, 4, "the first run's four proposals are superseded")

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
        XCTAssertEqual(project.openQuestions.count, 1)
        XCTAssertEqual(project.nextAgenda.count, 1)
    }

    func testReExtractingKeepsItemsTheUserHasAlreadyActedOn() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        // Simulate the review step. Stable provider-key identity means the next extraction resolves
        // to these same records; it must not append pending-review duplicates beside them.
        var project = try await storedProject()
        let decisionCreatedAt = project.decisions[0].createdAt
        let questionCreatedAt = project.openQuestions[0].createdAt
        project.decisions[0].status = .confirmed
        project.openQuestions[0].status = .resolved
        try await repository.save(project)

        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.decisions.count, 1, "the confirmed record remains the stable identity")
        XCTAssertEqual(updated.decisions.filter { $0.status == .confirmed }.count, 1)
        XCTAssertEqual(updated.decisions[0].createdAt, decisionCreatedAt)
        XCTAssertEqual(updated.openQuestions.count, 1)
        XCTAssertEqual(updated.openQuestions.filter { $0.status == .resolved }.count, 1)
        XCTAssertEqual(updated.openQuestions[0].createdAt, questionCreatedAt)
    }

    func testReExtractingKeepsApprovedOpenQuestionsAndAgendaItems() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        // Approve both through the real review service. Neither changes status — an approved open
        // question is still `.open` and an approved agenda item is still `.pending` — so only
        // `reviewedAt` distinguishes them from a fresh proposal.
        let reviewService = WorkStateReviewService(repository: repository, now: { TestFixtures.laterDate })
        let approved = try await storedProject()
        let questionCreatedAt = approved.openQuestions[0].createdAt
        let agendaCreatedAt = approved.nextAgenda[0].createdAt
        try await reviewService.approveOpenQuestion(id: approved.openQuestions[0].id, in: approved.id)
        try await reviewService.approveAgendaItem(id: approved.nextAgenda[0].id, in: approved.id)

        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.openQuestions.count, 1, "the approved question remains the stable identity")
        XCTAssertEqual(updated.openQuestions.filter { $0.reviewedAt != nil }.count, 1)
        XCTAssertEqual(updated.openQuestions[0].createdAt, questionCreatedAt)
        XCTAssertEqual(updated.nextAgenda.count, 1, "the approved agenda item remains the stable identity")
        XCTAssertEqual(updated.nextAgenda.filter { $0.reviewedAt != nil }.count, 1)
        XCTAssertEqual(updated.nextAgenda[0].createdAt, agendaCreatedAt)
    }

    func testReExtractingKeepsHandEnteredAgendaItemsThatHaveNoEvidence() async throws {
        var project = try await storedProject()
        project.nextAgenda.append(
            AgendaItem(
                id: UUID(),
                projectID: project.id,
                title: "사용자가 직접 추가한 아젠다",
                reason: "직접 입력",
                sourceMeetingID: meeting.id,
                relatedActionItemID: nil,
                relatedOpenQuestionID: nil,
                status: .pending,
                createdAt: TestFixtures.fixedDate
            )
        )
        try await repository.save(project)

        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.nextAgenda.filter { $0.evidence == nil }.count, 1)
        XCTAssertEqual(updated.nextAgenda.filter { $0.evidence != nil }.count, 1)
    }

    private func makeDecision(id: UUID, status: DecisionStatus, evidence: EvidenceReference?) -> Decision {
        Decision(
            id: id, projectID: TestFixtures.projectID, meetingID: meeting.id,
            statement: "결정 \(id.uuidString.prefix(4))", rationale: nil, status: status, evidence: evidence,
            confidence: Confidence(0.5), createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate
        )
    }

    private func makeActionItem(id: UUID, status: ActionItemStatus, evidence: EvidenceReference?) -> ActionItem {
        ActionItem(
            id: id, projectID: TestFixtures.projectID, meetingID: meeting.id,
            title: "업무 \(id.uuidString.prefix(4))", details: nil, assigneeID: nil, dueDate: nil,
            status: status, evidence: evidence, confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate
        )
    }

    private func makeOpenQuestion(
        id: UUID, status: OpenQuestionStatus, evidence: EvidenceReference?, reviewedAt: Date?
    ) -> OpenQuestion {
        OpenQuestion(
            id: id, projectID: TestFixtures.projectID, meetingID: meeting.id,
            question: "질문 \(id.uuidString.prefix(4))", status: status, evidence: evidence,
            confidence: Confidence(0.5), createdAt: TestFixtures.fixedDate, resolvedAt: nil, reviewedAt: reviewedAt
        )
    }

    private func makeAgendaItem(
        id: UUID, status: AgendaItemStatus, evidence: EvidenceReference?, reviewedAt: Date?
    ) -> AgendaItem {
        AgendaItem(
            id: id, projectID: TestFixtures.projectID, title: "아젠다 \(id.uuidString.prefix(4))",
            reason: "이유", sourceMeetingID: meeting.id, relatedActionItemID: nil, relatedOpenQuestionID: nil,
            status: status, createdAt: TestFixtures.fixedDate,
            evidence: evidence, confidence: evidence == nil ? nil : Confidence(0.5), reviewedAt: reviewedAt
        )
    }

    func testReExtractingPreservesEvidencelessProposedDecisionAndActionItem() async throws {
        // A `.proposed` Decision/ActionItem with no evidence cannot be produced by this app's own
        // extraction path today (the mapper always attaches grounded evidence), but the policy
        // must not depend on that — this is the exact bug class `PendingAIProposalPolicy` closes.
        var project = try await storedProject()
        project.decisions.append(makeDecision(id: UUID(), status: .proposed, evidence: nil))
        project.actionItems.append(makeActionItem(id: UUID(), status: .proposed, evidence: nil))
        try await repository.save(project)

        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.decisions.filter { $0.evidence == nil }.count, 1, "the evidence-less proposed decision must survive")
        XCTAssertEqual(updated.decisions.filter { $0.evidence != nil }.count, 1, "the newly extracted decision must still be stored")
        XCTAssertEqual(updated.actionItems.filter { $0.evidence == nil }.count, 1)
        XCTAssertEqual(updated.actionItems.filter { $0.evidence != nil }.count, 1)
    }

    /// The strongest form of "inbox and re-extraction use one policy": build a project covering
    /// every pending/not-pending combination across all four types, capture what the inbox shows
    /// as pending, run a re-extraction that adds nothing, and assert the set of items removed is
    /// exactly the set the inbox called pending — no more, no less.
    func testInboxPendingSetExactlyMatchesReExtractionRemovalSet() async throws {
        let evidence = ReviewFixtures.evidence

        var project = try await storedProject()
        project.decisions = [
            makeDecision(id: UUID(), status: .proposed, evidence: nil),        // not pending: no evidence
            makeDecision(id: UUID(), status: .proposed, evidence: evidence),   // pending
            makeDecision(id: UUID(), status: .confirmed, evidence: evidence)   // not pending: reviewed
        ]
        project.actionItems = [
            makeActionItem(id: UUID(), status: .proposed, evidence: nil)       // not pending: no evidence
        ]
        project.openQuestions = [
            makeOpenQuestion(id: UUID(), status: .open, evidence: evidence, reviewedAt: nil),                  // pending
            makeOpenQuestion(id: UUID(), status: .open, evidence: nil, reviewedAt: nil),                       // not pending: no evidence
            makeOpenQuestion(id: UUID(), status: .open, evidence: evidence, reviewedAt: TestFixtures.laterDate) // not pending: approved
        ]
        project.nextAgenda = [
            makeAgendaItem(id: UUID(), status: .pending, evidence: evidence, reviewedAt: nil),                                  // pending
            makeAgendaItem(id: UUID(), status: .dismissed, evidence: evidence, reviewedAt: TestFixtures.laterDate)              // not pending: reviewed
        ]
        try await repository.save(project)

        let seeded = try await storedProject()
        let allIDsBefore = Set(
            seeded.decisions.map(\.id) + seeded.actionItems.map(\.id)
                + seeded.openQuestions.map(\.id) + seeded.nextAgenda.map(\.id)
        )
        let pendingIDsPerInbox = Set(WorkStateInbox.pendingProposals(in: seeded).map(\.id))

        // An extraction with nothing to add: the only effect left is what re-extraction removes.
        let service = makeService(.success(ExtractionFixtures.emptyResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let after = try await storedProject()
        let survivingIDs = Set(
            after.decisions.map(\.id) + after.actionItems.map(\.id)
                + after.openQuestions.map(\.id) + after.nextAgenda.map(\.id)
        )
        let removedIDs = allIDsBefore.subtracting(survivingIDs)

        XCTAssertEqual(removedIDs, pendingIDsPerInbox, "re-extraction must remove exactly what the inbox called pending")
        XCTAssertEqual(survivingIDs, allIDsBefore.subtracting(pendingIDsPerInbox), "everything not shown as pending must survive")
    }

    func testReExtractingOneMeetingLeavesAnotherMeetingsProposalsAlone() async throws {
        let otherMeeting = ExtractionFixtures.meeting(id: UUID(), segmentID: UUID())
        var project = try await storedProject()
        project.meetings.append(otherMeeting)
        try await repository.save(project)

        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let otherService = WorkStateExtractionService(
            repository: repository,
            extractor: StubWorkStateExtractor(.success(
                ExtractionFixtures.fullResult(
                    evidence: ExtractionFixtures.evidence(segmentID: otherMeeting.transcriptSegments[0].id)
                )
            )),
            now: { TestFixtures.laterDate }
        )
        _ = try await otherService.extractAndApply(meetingID: otherMeeting.id, projectID: project.id)

        let updated = try await storedProject()
        XCTAssertEqual(updated.decisions.count, 2)
        XCTAssertEqual(updated.decisions.filter { $0.meetingID == meeting.id }.count, 1)
        XCTAssertEqual(updated.decisions.filter { $0.meetingID == otherMeeting.id }.count, 1)
    }

    // MARK: - Persistence

    func testStoredProposalsSurviveAJSONRepositoryReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Extraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("projects.json")
        let writer = JSONProjectRepository(fileURL: fileURL)
        try await writer.save(ExtractionFixtures.project(with: [meeting]))

        let service = makeService(.success(ExtractionFixtures.fullResult()), repository: writer)
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        // A second instance pointed at the same file is the closest equivalent to relaunching.
        let reader = JSONProjectRepository(fileURL: fileURL)
        let reloadedProject = try await reader.project(id: TestFixtures.projectID)
        let reloaded = try XCTUnwrap(reloadedProject)

        XCTAssertEqual(reloaded.decisions.count, 1)
        XCTAssertEqual(reloaded.actionItems.count, 1)
        XCTAssertEqual(reloaded.openQuestions.count, 1)
        XCTAssertEqual(reloaded.nextAgenda.count, 1)

        XCTAssertEqual(reloaded.decisions[0].status, .proposed)
        XCTAssertEqual(reloaded.decisions[0].evidence?.quote, "2월 출시로 가기로 했습니다")
        XCTAssertEqual(reloaded.decisions[0].confidence, Confidence(0.8))
        XCTAssertEqual(reloaded.nextAgenda[0].confidence, Confidence(0.8))
        XCTAssertEqual(reloaded.nextAgenda[0].evidence?.transcriptSegmentID, TestFixtures.segmentID)
    }
}

/// Collects the phase markers the detached recorder writes.
///
/// The recorder deliberately does not tell its caller when a mark landed, so the probe polls the
/// store until the count settles rather than awaiting anything the extraction path can see.
private struct PhaseProbe {
    let store = InMemoryBetaMetricsRepository()

    var recorder: ExtractionPhaseRecorder {
        ExtractionPhaseRecorder(
            runID: UUID(uuidString: "44000000-0000-4000-8000-000000000001")!,
            projectID: TestFixtures.projectID,
            meetingID: nil,
            metrics: BetaMetricsService(repository: store),
            elapsedMilliseconds: { 0 }
        )
    }

    func reachedPhases() async throws -> [BetaMetricExtractionPhase] {
        var previous = -1
        for _ in 0..<200 {
            let events = try await store.store().events.filter { $0.type == .extractionPhase }
            if events.count == previous, previous >= 0 { break }
            previous = events.count
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let events = try await store.store().events.filter { $0.type == .extractionPhase }
        return events
            .compactMap(\.extractionPhase)
            .sorted { $0.sequence < $1.sequence }
    }
}

private struct PhaseFailingProjectRepository: ProjectRepository {
    enum SimulatedError: Error { case save }

    let stored: Project

    func save(_ project: Project) async throws { throw SimulatedError.save }
    func project(id: UUID) async throws -> Project? { stored.id == id ? stored : nil }
    func allProjects() async throws -> [Project] { [stored] }
    func delete(id: UUID) async throws {}
}

/// The recovery path for a meeting that was saved but never analysed.
///
/// Kept in this file rather than a new one because it is the same boundary from the other side:
/// `WorkStateExtractionService` decides what a run does, and `MeetingReanalysisService` decides
/// whether a run may happen at all.
final class MeetingReanalysisServiceTests: XCTestCase {
    private var meeting: Meeting!
    private var repository: InMemoryProjectRepository!
    private var transitions: InMemoryWorkStateTransitionRepository!

    override func setUp() async throws {
        meeting = ExtractionFixtures.meeting(
            participants: [
                Participant(
                    id: TestFixtures.participantID,
                    displayName: "Patrick",
                    linkedUserID: nil,
                    speakerLabel: "Patrick"
                )
            ]
        )
        repository = InMemoryProjectRepository()
        transitions = InMemoryWorkStateTransitionRepository()
        try await repository.save(ExtractionFixtures.project(with: [meeting]))
    }

    private func makeService(
        extractor: CountingWorkStateExtractor,
        repository: (any ProjectRepository)? = nil,
        transitions: (any WorkStateTransitionRepository)? = nil
    ) -> MeetingReanalysisService {
        let projects = repository ?? self.repository!
        let store = transitions ?? self.transitions!
        return MeetingReanalysisService(
            repository: projects,
            extraction: WorkStateExtractionService(
                repository: projects,
                extractor: extractor,
                continuity: WorkStateContinuityService(projects: projects, transitions: store),
                now: { TestFixtures.laterDate }
            ),
            transitions: store
        )
    }

    private func storedProject(
        from repository: (any ProjectRepository)? = nil
    ) async throws -> Project {
        let repository = repository ?? self.repository!
        let project = try await repository.project(id: TestFixtures.projectID)
        return try XCTUnwrap(project)
    }

    // MARK: - Offering the retry

    /// The case that made this feature necessary: extraction failed after the meeting was already
    /// stored, and until now there was nowhere in the app to run it again.
    func testMeetingWhoseExtractionFailedIsStillEligibleAfterwards() async throws {
        let extractor = CountingWorkStateExtractor(.failure(.credentialInteractionRequired))
        let service = makeService(extractor: extractor)

        do {
            _ = try await service.reanalyse(
                meetingID: meeting.id,
                projectID: meeting.projectID
            )
            XCTFail("a failing provider must not report success")
        } catch let refusal as MeetingReanalysisRefused {
            XCTFail("expected the provider error, not a refusal: \(refusal.reason)")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .credentialInteractionRequired)
        }

        // The meeting is untouched and the offer stands, without anything having been written down
        // to remember that the run failed.
        let project = try await storedProject()
        XCTAssertEqual(project.meetings.count, 1)
        XCTAssertEqual(project.meetings.first?.id, meeting.id)
        let eligibility = await service.eligibility(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .eligible)
    }

    func testMeetingWithoutATranscriptIsNotOffered() async throws {
        var emptyMeeting = meeting!
        emptyMeeting.transcriptSegments = []
        try await repository.save(ExtractionFixtures.project(with: [emptyMeeting]))

        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        let eligibility = await service.eligibility(
            meetingID: emptyMeeting.id,
            projectID: emptyMeeting.projectID
        )
        XCTAssertEqual(eligibility, .transcriptMissing)

        await XCTAssertThrowsRefusal(.transcriptMissing) {
            try await service.reanalyse(meetingID: emptyMeeting.id, projectID: emptyMeeting.projectID)
        }
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testDeletedMeetingIsNotOffered() async throws {
        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        let eligibility = await service.eligibility(
            meetingID: UUID(),
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .meetingNotFound)
    }

    // MARK: - What a retry reuses

    func testRetryReusesTheStoredMeetingSegmentAndParticipants() async throws {
        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        _ = try await service.reanalyse(meetingID: meeting.id, projectID: meeting.projectID)

        let sent = await extractor.receivedInputs
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.meetingID, meeting.id)
        XCTAssertEqual(sent.first?.excerpts.map(\.segmentID), [TestFixtures.segmentID])
        // The retry crosses the provider boundary on exactly the terms a first run does: the input
        // type carries no participant identifier at all, so re-running cannot widen what is sent.
        XCTAssertFalse(
            sent.first?.excerpts.contains { $0.text.contains(TestFixtures.participantID.uuidString) } ?? true
        )

        // No second meeting, no second transcript, no re-typing: the counts are exactly what they
        // were before the retry ran.
        let project = try await storedProject()
        XCTAssertEqual(project.meetings.count, 1)
        let stored = try XCTUnwrap(project.meetings.first)
        XCTAssertEqual(stored.id, meeting.id)
        XCTAssertEqual(stored.transcriptSegments.map(\.id), [TestFixtures.segmentID])
        XCTAssertEqual(stored.participants.map(\.id), [TestFixtures.participantID])
    }

    /// A successful retry produces suggestions, not decisions. Nothing it writes is approved, and
    /// no project work state changes state on its own.
    func testSuccessfulRetryLeavesEverythingWaitingOnAPerson() async throws {
        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        _ = try await service.reanalyse(meetingID: meeting.id, projectID: meeting.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.map(\.status), [.proposed])
        XCTAssertEqual(project.actionItems.map(\.status), [.proposed])
        XCTAssertTrue(project.openQuestions.allSatisfy { $0.reviewedAt == nil })
        XCTAssertTrue(project.nextAgenda.allSatisfy { $0.reviewedAt == nil })

        let proposals = try await transitions.proposals(forProject: meeting.projectID)
        XCTAssertFalse(proposals.isEmpty)
        XCTAssertTrue(proposals.allSatisfy { $0.reviewStatus == .pendingReview })
        XCTAssertTrue(proposals.allSatisfy { $0.sourceMeetingID == self.meeting.id })
    }

    // MARK: - Not calling the provider twice

    func testMeetingThatAlreadyHasResultsIsRefusedWithoutCallingTheProvider() async throws {
        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        _ = try await service.reanalyse(meetingID: meeting.id, projectID: meeting.projectID)
        let afterFirst = await extractor.callCount
        XCTAssertEqual(afterFirst, 1)

        let eligibility = await service.eligibility(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .alreadyAnalysed)

        await XCTAssertThrowsRefusal(.alreadyAnalysed) {
            try await service.reanalyse(meetingID: self.meeting.id, projectID: self.meeting.projectID)
        }
        let afterSecond = await extractor.callCount
        XCTAssertEqual(afterSecond, 1, "a meeting with results must not be sent again")
    }

    /// A run can leave continuity proposals without leaving any work state of its own — a meeting
    /// whose only outcome was moving earlier work forward. That meeting has been analysed too.
    func testMeetingWithOnlyTransitionProposalsIsRefused() async throws {
        let dedupKey = "reanalysis-test-only-transition"
        let proposal = WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: dedupKey),
            projectID: meeting.projectID,
            workStateKind: .decision,
            transitionKind: .new,
            previousStateID: nil,
            currentObjectID: UUID(),
            sourceMeetingID: meeting.id,
            evidence: nil,
            basis: .noPriorCandidate,
            requiresConfirmation: true,
            dedupKey: dedupKey,
            createdAt: TestFixtures.fixedDate
        )
        try await transitions.upsert([proposal])

        let extractor = CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult()))
        let service = makeService(extractor: extractor)

        let eligibility = await service.eligibility(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .alreadyAnalysed)
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 0)
    }

    /// Two presses that overlap. The disabled button is a courtesy; this is the guarantee.
    func testOverlappingRetriesReachTheProviderOnce() async throws {
        let extractor = CountingWorkStateExtractor(
            .success(ExtractionFixtures.fullResult()),
            delay: .milliseconds(200)
        )
        let service = makeService(extractor: extractor)

        let meetingID = meeting.id
        let projectID = meeting.projectID
        async let first: Void = {
            _ = try? await service.reanalyse(meetingID: meetingID, projectID: projectID)
        }()
        async let second: Void = {
            _ = try? await service.reanalyse(meetingID: meetingID, projectID: projectID)
        }()
        _ = await (first, second)

        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 1, "one meeting must not produce two overlapping provider calls")
        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
    }

    // MARK: - Surviving a relaunch

    /// The reason this lives on the meeting screen and not only on the capture sheet: nothing about
    /// a failed run is stored, so the offer has to be recomputable from scratch by a new process.
    func testRetryIsStillOfferedAfterTheStoreIsReopened() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        try await writer.save(ExtractionFixtures.project(with: [meeting]))

        // A different repository instance over the same file is what a relaunch looks like from
        // here: no cached state carries over.
        let reader = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        let reopened = MeetingReanalysisService(
            repository: reader,
            extraction: WorkStateExtractionService(
                repository: reader,
                extractor: CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult())),
                now: { TestFixtures.laterDate }
            )
        )

        let eligibility = await reopened.eligibility(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .eligible)
    }

    func testResultsOfARetrySurviveTheStoreBeingReopened() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectsURL = directory.appendingPathComponent("projects.json")
        let transitionsURL = directory.appendingPathComponent("continuity-transitions.json")
        let writer = JSONProjectRepository(fileURL: projectsURL)
        let transitionWriter = JSONWorkStateTransitionRepository(fileURL: transitionsURL)
        try await writer.save(ExtractionFixtures.project(with: [meeting]))

        let service = MeetingReanalysisService(
            repository: writer,
            extraction: WorkStateExtractionService(
                repository: writer,
                extractor: CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult())),
                continuity: WorkStateContinuityService(
                    projects: writer,
                    transitions: transitionWriter
                ),
                now: { TestFixtures.laterDate }
            ),
            transitions: transitionWriter
        )
        _ = try await service.reanalyse(meetingID: meeting.id, projectID: meeting.projectID)

        let beforeIDs = try await Self.proposalIdentity(projectsURL: projectsURL, transitionsURL: transitionsURL)

        let reader = JSONProjectRepository(fileURL: projectsURL)
        let transitionReader = JSONWorkStateTransitionRepository(fileURL: transitionsURL)
        let afterIDs = try await Self.proposalIdentity(projectsURL: projectsURL, transitionsURL: transitionsURL)
        XCTAssertEqual(beforeIDs, afterIDs)

        let reloadedProject = try await reader.project(id: meeting.projectID)
        let reloaded = try XCTUnwrap(reloadedProject)
        XCTAssertEqual(reloaded.meetings.count, 1)
        XCTAssertEqual(reloaded.decisions.map(\.status), [.proposed])
        let proposals = try await transitionReader.proposals(forProject: meeting.projectID)
        XCTAssertFalse(proposals.isEmpty)
        XCTAssertTrue(proposals.allSatisfy { $0.reviewStatus == .pendingReview })

        // And the offer is correctly gone: the meeting has results now, so the screen shows them
        // rather than offering to fetch them again.
        let reopened = MeetingReanalysisService(
            repository: reader,
            extraction: WorkStateExtractionService(
                repository: reader,
                extractor: CountingWorkStateExtractor(.success(ExtractionFixtures.fullResult())),
                now: { TestFixtures.laterDate }
            ),
            transitions: transitionReader
        )
        let eligibility = await reopened.eligibility(
            meetingID: meeting.id,
            projectID: meeting.projectID
        )
        XCTAssertEqual(eligibility, .alreadyAnalysed)
    }

    // MARK: - What the screen is allowed to say

    /// No transcript text, no meeting title, no provider text. Same rule as `CaptureFailureCopy`:
    /// a message about a failure must not become a second place a user's meeting is written down.
    func testRefusalCopyNeverCarriesMeetingContent() {
        let reasons: [MeetingReanalysisEligibility] = [
            .eligible, .meetingNotFound, .transcriptMissing,
            .alreadyAnalysed, .alreadyRunning, .storeUnavailable
        ]
        for reason in reasons {
            let text = MeetingReanalysisCopy.refusal(reason)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(ExtractionFixtures.transcript))
            XCTAssertFalse(text.contains("Kickoff"))
            XCTAssertFalse(text.contains("Patrick"))
        }
        XCTAssertFalse(MeetingReanalysisCopy.availability.contains(ExtractionFixtures.transcript))
    }

    // MARK: - Helpers

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENAReanalysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func proposalIdentity(
        projectsURL: URL,
        transitionsURL: URL
    ) async throws -> [String] {
        let projects = JSONProjectRepository(fileURL: projectsURL)
        let transitions = JSONWorkStateTransitionRepository(fileURL: transitionsURL)
        let project = try await projects.project(id: TestFixtures.projectID)
        let workStateIDs = (project?.decisions.map(\.id.uuidString) ?? [])
            + (project?.actionItems.map(\.id.uuidString) ?? [])
            + (project?.openQuestions.map(\.id.uuidString) ?? [])
            + (project?.nextAgenda.map(\.id.uuidString) ?? [])
        let transitionIDs = try await transitions
            .proposals(forProject: TestFixtures.projectID)
            .map(\.id.uuidString)
        return (workStateIDs + transitionIDs).sorted()
    }
}

/// Asserts that a re-analysis was refused for a specific reason rather than run or thrown from.
private func XCTAssertThrowsRefusal(
    _ expected: MeetingReanalysisEligibility,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected a refusal for \(expected)", file: file, line: line)
    } catch let refusal as MeetingReanalysisRefused {
        XCTAssertEqual(refusal.reason, expected, file: file, line: line)
    } catch {
        XCTFail("expected a refusal, got \(error)", file: file, line: line)
    }
}
