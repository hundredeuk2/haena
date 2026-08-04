import Foundation
@testable import HAENA

/// A project carrying one unreviewed proposal of each kind, plus the participants an action item
/// can legitimately be assigned to.
enum ReviewFixtures {
    static let assignee = Participant(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        displayName: "서연",
        linkedUserID: nil,
        speakerLabel: nil
    )
    static let otherParticipant = Participant(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        displayName: "민준",
        linkedUserID: nil,
        speakerLabel: nil
    )

    static let decisionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    static let actionItemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let openQuestionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let agendaItemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!

    static let evidence = EvidenceReference(
        meetingID: TestFixtures.meetingID,
        transcriptSegmentID: TestFixtures.segmentID,
        quote: "2월 출시로 가기로 했습니다"
    )

    static func meeting() -> Meeting {
        ExtractionFixtures.meeting(participants: [assignee, otherParticipant])
    }

    static func decision(status: DecisionStatus = .proposed) -> Decision {
        Decision(
            id: decisionID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            statement: "2월 출시로 진행한다",
            rationale: nil,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.8),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    static func actionItem(status: ActionItemStatus = .proposed) -> ActionItem {
        ActionItem(
            id: actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "지표 정의 초안 작성",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.7),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    static func openQuestion(status: OpenQuestionStatus = .open, reviewedAt: Date? = nil) -> OpenQuestion {
        OpenQuestion(
            id: openQuestionID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            question: "지표 정의는 누가 확정하는가?",
            status: status,
            evidence: evidence,
            confidence: Confidence(0.6),
            createdAt: TestFixtures.fixedDate,
            resolvedAt: nil,
            reviewedAt: reviewedAt
        )
    }

    static func agendaItem(
        status: AgendaItemStatus = .pending,
        reviewedAt: Date? = nil,
        evidence: EvidenceReference? = ReviewFixtures.evidence
    ) -> AgendaItem {
        AgendaItem(
            id: agendaItemID,
            projectID: TestFixtures.projectID,
            title: "지표 정의 확정",
            reason: "이번 회의에서 결론이 나지 않음",
            sourceMeetingID: TestFixtures.meetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: status,
            createdAt: TestFixtures.fixedDate,
            evidence: evidence,
            confidence: evidence == nil ? nil : Confidence(0.5),
            reviewedAt: reviewedAt
        )
    }

    static func project(
        decisions: [Decision]? = nil,
        actionItems: [ActionItem]? = nil,
        openQuestions: [OpenQuestion]? = nil,
        nextAgenda: [AgendaItem]? = nil
    ) -> Project {
        Project(
            id: TestFixtures.projectID,
            name: "HAE.NA",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [meeting()],
            decisions: decisions ?? [decision()],
            actionItems: actionItems ?? [actionItem()],
            openQuestions: openQuestions ?? [openQuestion()],
            nextAgenda: nextAgenda ?? [agendaItem()]
        )
    }
}
