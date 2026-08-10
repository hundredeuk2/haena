import XCTest
@testable import HAENA

final class AgentLedgerPresentationTests: XCTestCase {
    private let actionItemID = UUID(uuidString: "71000000-0000-4000-8000-000000000001")!
    private let eventID = UUID(uuidString: "71000000-0000-4000-8000-000000000002")!
    private let reminderID = UUID(uuidString: "71000000-0000-4000-8000-000000000004")!

    func testDeletedReferencesUseHumanFallbacksWithoutExposingIdentifiers() {
        let event = makeEvent(projectID: TestFixtures.projectID, actionItemID: actionItemID)

        let row = AgentLedgerPresentation.rows(events: [event], projects: []).first

        XCTAssertEqual(row?.projectName, "삭제된 프로젝트")
        XCTAssertEqual(row?.actionItemTitle, "삭제된 업무")
        XCTAssertFalse(row?.projectName.contains(TestFixtures.projectID.uuidString) == true)
        XCTAssertFalse(row?.actionItemTitle.contains(actionItemID.uuidString) == true)
    }

    func testDeletedActionItemStillResolvesExistingProjectName() {
        let project = makeProject(actionItems: [])
        let event = makeEvent(projectID: project.id, actionItemID: actionItemID)

        let row = AgentLedgerPresentation.rows(events: [event], projects: [project]).first

        XCTAssertEqual(row?.projectName, "Private Agent 검증")
        XCTAssertEqual(row?.actionItemTitle, "삭제된 업무")
    }

    func testExistingReferencesResolveCurrentNames() {
        let item = makeActionItem()
        let project = makeProject(actionItems: [item])
        let event = makeEvent(projectID: project.id, actionItemID: item.id)

        let row = AgentLedgerPresentation.rows(events: [event], projects: [project]).first

        XCTAssertEqual(row?.projectName, "Private Agent 검증")
        XCTAssertEqual(row?.actionItemTitle, "반복 사용 기록 확인")
    }

    func testRowsAreMostRecentFirstAndFeedbackEventsAreFoldedAway() {
        let older = makeEvent(id: eventID, occurredAt: TestFixtures.fixedDate)
        let newerID = UUID(uuidString: "71000000-0000-4000-8000-000000000003")!
        let newer = makeEvent(
            id: newerID,
            type: .fireTimeReached,
            occurredAt: TestFixtures.laterDate
        )
        let feedback = makeEvent(
            id: UUID(uuidString: "71000000-0000-4000-8000-000000000005")!,
            type: .feedback,
            occurredAt: TestFixtures.laterDate.addingTimeInterval(1),
            feedback: .helpful
        )

        let rows = AgentLedgerPresentation.rows(events: [older, feedback, newer], projects: [])

        XCTAssertEqual(rows.map(\.id), [newerID, eventID])
        XCTAssertEqual(rows.first?.feedback, .helpful)
        XCTAssertEqual(rows.filter(\.acceptsFeedback).count, 1)
    }

    func testPassedTimeCopyDoesNotClaimNotificationWasDisplayedOrDelivered() {
        let event = makeEvent(type: .fireTimeReached)

        let label = AgentLedgerPresentation.factLabel(for: event, dateFormatter: utcFormatter)

        XCTAssertTrue(label.hasPrefix("예약 시각 지남"))
        XCTAssertFalse(label.contains("표시"))
        XCTAssertFalse(label.contains("전달"))
        XCTAssertFalse(label.contains("수신"))
    }

    func testForegroundPresentationStatesCallbackRatherThanUserAttention() {
        let event = makeEvent(type: .presentedForeground)

        let label = AgentLedgerPresentation.factLabel(for: event)

        XCTAssertEqual(label, "앱 사용 중 알림 표시 콜백 수신")
        XCTAssertFalse(label.contains("확인함"))
        XCTAssertFalse(label.contains("봤"))
    }

    func testNotificationOpenStatesObservedInteraction() {
        XCTAssertEqual(
            AgentLedgerPresentation.factLabel(for: makeEvent(type: .openedFromNotification)),
            "알림 열기 응답 수신"
        )
    }

    func testCancellationCopyDistinguishesUserAndPolicyActions() {
        let user = makeEvent(
            type: .cancelled,
            cancellation: AgentLedgerCancellation(source: .user, reason: .userCancelled)
        )
        let policy = makeEvent(
            type: .cancelled,
            cancellation: AgentLedgerCancellation(source: .policy, reason: .actionItemCompleted)
        )

        XCTAssertEqual(
            AgentLedgerPresentation.factLabel(for: user),
            "사용자가 알림 예약 취소함"
        )
        XCTAssertEqual(
            AgentLedgerPresentation.factLabel(for: policy),
            "상태에 따라 알림 예약 자동 취소됨"
        )
    }

    func testCompletionCopyStatesSequenceWithoutClaimingCausality() {
        let label = AgentLedgerPresentation.factLabel(
            for: makeEvent(type: .taskCompletedAfterReminder)
        )

        XCTAssertEqual(label, "알림 기록 뒤 업무 완료 처리됨")
        XCTAssertFalse(label.contains("덕분"))
        XCTAssertFalse(label.contains("때문"))
    }

    func testSchedulingWithoutStoredFireDateSaysItIsMissing() {
        let label = AgentLedgerPresentation.factLabel(
            for: makeEvent(type: .scheduled, scheduledFor: nil)
        )

        XCTAssertEqual(label, "알림 예약됨 · 예약 시각 없음")
    }

    func testFeedbackFailureCopyOnlyMatchesItsReminderRow() throws {
        let targetRow = try XCTUnwrap(
            AgentLedgerPresentation.rows(events: [makeEvent(type: .fireTimeReached)], projects: []).first
        )
        let otherEvent = AgentLedgerEvent(
            id: UUID(uuidString: "71000000-0000-4000-8000-000000000006")!,
            deduplicationKey: "fire:other",
            reminderID: UUID(uuidString: "71000000-0000-4000-8000-000000000007")!,
            projectID: TestFixtures.projectID,
            actionItemID: actionItemID,
            type: .fireTimeReached,
            occurredAt: TestFixtures.laterDate,
            scheduledFor: TestFixtures.laterDate
        )
        let otherRow = try XCTUnwrap(
            AgentLedgerPresentation.rows(events: [otherEvent], projects: []).first
        )
        let failure = AgentLedgerFeedbackFailure(reminderID: reminderID)

        XCTAssertEqual(failure.message(for: targetRow), AgentLedgerFeedbackFailure.copy)
        XCTAssertNil(failure.message(for: otherRow))
    }

    private var utcFormatter: AgentLedgerDateFormatter {
        AgentLedgerDateFormatter(
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func makeEvent(
        id: UUID? = nil,
        projectID: UUID = TestFixtures.projectID,
        actionItemID: UUID? = nil,
        type: AgentLedgerEventType = .scheduled,
        occurredAt: Date = TestFixtures.fixedDate,
        scheduledFor: Date? = TestFixtures.laterDate,
        cancellation: AgentLedgerCancellation? = nil,
        feedback: AgentLedgerFeedback? = nil
    ) -> AgentLedgerEvent {
        AgentLedgerEvent(
            id: id ?? eventID,
            deduplicationKey: "\(type.rawValue):\((id ?? eventID).uuidString)",
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID ?? self.actionItemID,
            type: type,
            occurredAt: occurredAt,
            scheduledFor: scheduledFor,
            cancellation: cancellation,
            feedback: feedback
        )
    }

    private func makeProject(actionItems: [ActionItem]) -> Project {
        Project(
            id: TestFixtures.projectID,
            name: "Private Agent 검증",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: actionItems,
            openQuestions: [],
            nextAgenda: []
        )
    }

    private func makeActionItem() -> ActionItem {
        ActionItem(
            id: actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "반복 사용 기록 확인",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .completed,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }
}
