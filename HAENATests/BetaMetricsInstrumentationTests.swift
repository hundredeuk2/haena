import XCTest
@testable import HAENA

/// Covers the instrumentation attached to the existing capture and review flows: that a successful
/// operation is counted once, that a failed one is not counted at all, and — above everything else
/// here — that a broken metrics store cannot break the operation it was measuring.
final class BetaMetricsInstrumentationTests: XCTestCase {

    // MARK: - Capture: what reached storage is what gets counted

    func testASuccessfulPastedTextCaptureRecordsOneMeetingProcessedWithItsSource() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: []))
        let probe = MetricsProbe()
        let capture = TextMeetingCaptureService(repository: repository)

        let meeting = try await capture.saveTextMeeting(
            projectID: TestFixtures.projectID,
            title: "Kickoff",
            transcript: ExtractionFixtures.transcript
        )
        let run = CaptureRun(source: .pastedText, metrics: probe.service)
        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: repository)
        await run.recordSuccess(outcome)

        let processed = await probe.meetingsProcessed()
        XCTAssertEqual(processed.count, 1, "a capture that reached storage is counted exactly once")
        XCTAssertEqual(processed.first?.meetingID ?? nil, meeting.id)
        XCTAssertEqual(processed.first?.source ?? nil, .pastedText)
    }

    func testEachCapturePathIsCountedUnderItsOwnSource() async throws {
        for source in [BetaMetricCaptureSource.pastedText, .importedAudio, .recordedAudio] {
            let repository = InMemoryProjectRepository()
            try await repository.save(ExtractionFixtures.project(with: [ExtractionFixtures.meeting()]))
            let probe = MetricsProbe()

            let outcome = await CaptureOutcome.make(
                for: ExtractionFixtures.meeting(),
                notice: nil,
                repository: repository
            )
            await CaptureRun(source: source, metrics: probe.service).recordSuccess(outcome)

            let processed = await probe.meetingsProcessed()
            XCTAssertEqual(processed.compactMap(\.source), [source])
        }
    }

    func testAFailedCaptureRecordsNoMeetingProcessed() async throws {
        let repository = InMemoryProjectRepository()
        let probe = MetricsProbe()
        let capture = TextMeetingCaptureService(repository: repository)
        let run = CaptureRun(source: .pastedText, metrics: probe.service)

        do {
            // No project was ever saved, so this is a capture that never reaches storage.
            _ = try await capture.saveTextMeeting(
                projectID: TestFixtures.projectID,
                title: "Kickoff",
                transcript: ExtractionFixtures.transcript
            )
            XCTFail("Expected the capture to fail")
        } catch {
            await run.recordFailure()
        }

        let processed = await probe.meetingsProcessed()
        XCTAssertTrue(processed.isEmpty, "nothing reached storage, so no meeting was processed")
    }

    func testDurationIsRecordedForBothSuccessAndFailureWithAFiniteOutcome() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: [ExtractionFixtures.meeting()]))
        let probe = MetricsProbe()

        let succeeded = CaptureRun(source: .importedAudio, metrics: probe.service)
        let outcome = await CaptureOutcome.make(
            for: ExtractionFixtures.meeting(),
            notice: nil,
            repository: repository
        )
        await succeeded.recordSuccess(outcome)

        let failed = CaptureRun(source: .importedAudio, metrics: probe.service)
        await failed.recordFailure()

        let durations = await probe.durations()
        XCTAssertEqual(durations.count, 2)
        XCTAssertEqual(Set(durations.compactMap(\.outcome)), [.succeeded, .failed])
        XCTAssertTrue(
            durations.allSatisfy { $0.milliseconds >= 0 },
            "a monotonic clock cannot produce a negative wait"
        )
        let failedDuration = durations.first { $0.outcome == .failed }
        XCTAssertNil(
            failedDuration?.meetingID ?? nil,
            "a capture that failed has no meeting to name"
        )
    }

    func testACaptureRunWithoutMetricsRecordsNothingAndStillReportsItsOutcome() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: [ExtractionFixtures.meeting()]))

        // The nil default is what every existing call site gets.
        let run = CaptureRun(source: .pastedText, metrics: nil)
        let outcome = await CaptureOutcome.make(
            for: ExtractionFixtures.meeting(),
            notice: nil,
            repository: repository
        )
        await run.recordSuccess(outcome)
        await run.recordFailure()

        XCTAssertEqual(outcome.meetingID, TestFixtures.meetingID)
    }

    // MARK: - Failure isolation
    //
    // The point of the whole design: `record*` is non-throwing, so a metrics failure has no path
    // into the flow it measures. These tests are the ones that must never be deleted.

    func testAMetricsFailureDoesNotStopACaptureFromSavingTheMeeting() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: []))
        let capture = TextMeetingCaptureService(repository: repository)

        let meeting = try await capture.saveTextMeeting(
            projectID: TestFixtures.projectID,
            title: "Kickoff",
            transcript: ExtractionFixtures.transcript
        )
        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: repository)
        // Every write this run attempts will fail.
        await CaptureRun(source: .pastedText, metrics: MetricsProbe.failingService).recordSuccess(outcome)

        let loaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.meetings.count, 1, "the meeting is still saved")
        XCTAssertEqual(stored.meetings[0].id, meeting.id)
        XCTAssertEqual(outcome.meetingID, meeting.id, "the user is still sent to their meeting")
    }

    func testAMetricsFailureDoesNotStopAVerdictFromBeingPersisted() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ReviewFixtures.project())
        let service = WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: MetricsProbe.failingService
        )

        // No `XCTAssertThrowsError` counterpart: any error thrown here fails the test outright,
        // which is exactly the claim being made.
        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await service.excludeActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await service.dismissAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        let loaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.decisions[0].status, .confirmed)
        XCTAssertEqual(stored.actionItems[0].status, .cancelled)
        XCTAssertEqual(stored.openQuestions[0].reviewedAt, TestFixtures.laterDate)
        XCTAssertEqual(stored.nextAgenda[0].status, .dismissed)
    }

    func testAMetricsFailureDoesNotStopAnActionItemCorrectionFromBeingPersisted() async throws {
        let repository = InMemoryProjectRepository()
        try await repository.save(ReviewFixtures.project())
        let service = WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: MetricsProbe.failingService
        )
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: due
        )

        let loaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.actionItems[0].assigneeID, ReviewFixtures.assignee.id)
        XCTAssertEqual(stored.actionItems[0].dueDate, due)
    }

    // MARK: - Verdicts

    func testApprovalsAcrossAllFourKindsNormalizeToApproved() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await service.approveActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await service.approveAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        let verdicts = await probe.verdicts()
        XCTAssertEqual(verdicts.count, 4)
        XCTAssertEqual(Set(verdicts.compactMap(\.verdict)), [.approved])
        XCTAssertEqual(
            Set(verdicts.compactMap(\.kind)),
            [.decision, .actionItem, .openQuestion, .agendaItem]
        )
    }

    func testExclusionsAcrossAllFourKindsNormalizeToExcluded() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        try await service.rejectDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await service.excludeActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.dismissOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await service.dismissAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        let verdicts = await probe.verdicts()
        XCTAssertEqual(verdicts.count, 4)
        XCTAssertEqual(Set(verdicts.compactMap(\.verdict)), [.excluded])
        XCTAssertEqual(
            Set(verdicts.compactMap(\.kind)),
            [.decision, .actionItem, .openQuestion, .agendaItem]
        )
    }

    func testAVerdictOnAMissingProjectRecordsNothing() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        do {
            try await service.approveDecision(id: ReviewFixtures.decisionID, in: UUID())
            XCTFail("Expected projectNotFound")
        } catch WorkStateReviewError.projectNotFound {
            // expected
        }

        let verdicts = await probe.verdicts()
        XCTAssertTrue(verdicts.isEmpty, "a verdict that was never applied is not a verdict")
    }

    func testAVerdictIsRecordedOnlyAfterTheWriteSucceeds() async throws {
        let probe = MetricsProbe()
        let service = WorkStateReviewService(
            repository: FailingProjectRepository(failOnSave: true, stored: ReviewFixtures.project()),
            now: { TestFixtures.laterDate },
            metrics: probe.service
        )

        do {
            try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
            XCTFail("Expected repositoryFailure")
        } catch WorkStateReviewError.repositoryFailure {
            // expected
        }

        let verdicts = await probe.verdicts()
        XCTAssertTrue(verdicts.isEmpty, "the store rejected the write, so nothing was reviewed")
    }

    func testHandEnteredItemsAreNeverRecordedAsProposals() async throws {
        let probe = MetricsProbe()
        var decision = ReviewFixtures.decision()
        decision.evidence = nil
        var actionItem = ReviewFixtures.actionItem()
        actionItem.evidence = nil
        var openQuestion = ReviewFixtures.openQuestion()
        openQuestion.evidence = nil

        let repository = InMemoryProjectRepository()
        try await repository.save(
            ReviewFixtures.project(
                decisions: [decision],
                actionItems: [actionItem],
                openQuestions: [openQuestion],
                nextAgenda: [ReviewFixtures.agendaItem(evidence: nil)]
            )
        )
        let service = WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: probe.service
        )

        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await service.approveActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await service.approveAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)
        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: nil
        )

        let verdicts = await probe.verdicts()
        let modifications = await probe.modifications()
        XCTAssertTrue(verdicts.isEmpty, "a record with no evidence belongs to its author, not to a model")
        XCTAssertTrue(modifications.isEmpty)

        let loaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.decisions[0].status, .confirmed, "the verdict itself still applied")
    }

    func testMovingAnAlreadyReviewedItemThroughItsLifecycleIsNotAVerdict() async throws {
        let probe = MetricsProbe()
        let repository = InMemoryProjectRepository()
        try await repository.save(
            ReviewFixtures.project(actionItems: [ReviewFixtures.actionItem(status: .confirmed)])
        )
        let service = WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: probe.service
        )

        try await service.setActionItemStatus(.completed, id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.approveActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)

        let verdicts = await probe.verdicts()
        XCTAssertTrue(verdicts.isEmpty, "a person already ruled on this one")
    }

    // MARK: - Corrections

    func testCorrectingAProposedProposalRecordsAFieldCategoryAgainstThatProposal() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        // Both correctable fields are filled in at once. The extraction got two things wrong, so two
        // facts are offered — one per field — and the store keeps both because it keys on the field
        // as well as the proposal. The *rate* still counts the proposal once; that is the summary's
        // job, and `BetaMetricsDomainTests` asserts it.
        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let modifications = await probe.modifications()
        XCTAssertEqual(modifications.count, 2, "one fact per field the user actually changed")
        XCTAssertEqual(
            Set(modifications.compactMap(\.proposalID)),
            [ReviewFixtures.actionItemID],
            "both are about the same proposal"
        )
        XCTAssertEqual(
            Set(modifications.compactMap(\.field)),
            [.assignee, .dueDate],
            "each corrected field is named exactly once"
        )
    }

    func testOnlyTheFieldsThatActuallyChangedAreRecorded() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        // The fixture has no assignee and no due date; only the due date is being filled in.
        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: nil,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let modifications = await probe.modifications()
        XCTAssertEqual(modifications.compactMap(\.field), [.dueDate])
    }

    func testCorrectingAnAlreadyReviewedActionItemRecordsNothing() async throws {
        let probe = MetricsProbe()
        let repository = InMemoryProjectRepository()
        try await repository.save(
            ReviewFixtures.project(actionItems: [ReviewFixtures.actionItem(status: .confirmed)])
        )
        let service = WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: probe.service
        )

        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let modifications = await probe.modifications()
        XCTAssertTrue(modifications.isEmpty, "editing a confirmed task is not correcting a proposal")

        let loaded = try await repository.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.actionItems[0].assigneeID, ReviewFixtures.assignee.id)
    }

    func testCorrectingTheSameProposalTwiceYieldsOneModifiedProposal() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: nil
        )
        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.otherParticipant.id,
            dueDate: nil
        )

        let modifications = await probe.modifications()
        XCTAssertEqual(
            Set(modifications.compactMap(\.proposalID)).count,
            1,
            "two corrections of one proposal are one proposal that needed correcting"
        )
        XCTAssertEqual(modifications.count, 1, "and are counted once")
    }

    func testAFailedCorrectionRecordsNothing() async throws {
        let probe = MetricsProbe()
        let service = try await makeReviewService(metrics: probe.service)

        do {
            try await service.updateActionItem(
                id: ReviewFixtures.actionItemID,
                in: TestFixtures.projectID,
                // Someone who was never in the room.
                assigneeID: UUID(),
                dueDate: nil
            )
            XCTFail("Expected unknownAssignee")
        } catch WorkStateReviewError.unknownAssignee {
            // expected
        }

        let modifications = await probe.modifications()
        XCTAssertTrue(modifications.isEmpty)
    }

    // MARK: - Helpers

    private func makeReviewService(metrics: BetaMetricsService) async throws -> WorkStateReviewService {
        let repository = InMemoryProjectRepository()
        try await repository.save(ReviewFixtures.project())
        return WorkStateReviewService(
            repository: repository,
            now: { TestFixtures.laterDate },
            metrics: metrics
        )
    }

    private struct FailingProjectRepository: ProjectRepository {
        enum SimulatedError: Error { case failure }

        var failOnSave: Bool
        var stored: Project?

        func save(_ project: Project) async throws {
            if failOnSave { throw SimulatedError.failure }
        }

        func project(id: UUID) async throws -> Project? {
            stored?.id == id ? stored : nil
        }

        func allProjects() async throws -> [Project] {
            stored.map { [$0] } ?? []
        }

        func delete(id: UUID) async throws {}
    }
}

// MARK: - Metrics probe

/// Reads back what the instrumentation actually recorded. The tests above speak only in the tuples
/// this returns, so they assert on the facts rather than on `BetaMetricEvent`'s shape.
private struct MetricsProbe {
    let store = InMemoryBetaMetricsRepository()

    var service: BetaMetricsService {
        BetaMetricsService(repository: store)
    }

    /// A metrics store where every write fails. Used to prove that a failure here is invisible to
    /// the capture or the verdict that triggered it.
    static var failingService: BetaMetricsService {
        BetaMetricsService(repository: FailingBetaMetricsRepository())
    }

    private func events(_ type: BetaMetricEventType) async -> [BetaMetricEvent] {
        let stored = try? await store.store().events
        return (stored ?? []).filter { $0.type == type }
    }

    func meetingsProcessed() async -> [(meetingID: UUID?, source: BetaMetricCaptureSource?, resultCount: Int?)] {
        await events(.meetingProcessed).map { ($0.meetingID, $0.captureSource, $0.resultCount) }
    }

    func durations() async -> [(source: BetaMetricCaptureSource?, outcome: BetaMetricOutcome?, milliseconds: Int, meetingID: UUID?)] {
        await events(.processingDuration).map {
            ($0.captureSource, $0.outcome, $0.durationMilliseconds ?? -1, $0.meetingID)
        }
    }

    func verdicts() async -> [(proposalID: UUID?, kind: BetaMetricProposalKind?, verdict: BetaMetricVerdict?)] {
        await events(.proposalReviewed).map { ($0.proposalID, $0.proposalKind, $0.verdict) }
    }

    func modifications() async -> [(proposalID: UUID?, field: BetaMetricFieldCategory?)] {
        await events(.proposalModified).map { ($0.proposalID, $0.fieldCategory) }
    }
}
