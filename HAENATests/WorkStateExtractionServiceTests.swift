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
