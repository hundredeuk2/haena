import Foundation
@testable import HAENA

/// A project with two meetings, whose every work-state record is built explicitly.
///
/// Nothing here has a "typical" shape: which meeting, which project, which review state and which
/// timestamps a record carries are exactly what the meeting-results tests are about, so each is a
/// parameter rather than a default buried in a convenience.
enum MeetingResultFixtures {
    static let projectA = TestFixtures.projectID
    static let projectB = uuid(900)
    static let meetingA = TestFixtures.meetingID
    static let meetingB = uuid(901)
    static let segmentA = TestFixtures.segmentID
    static let segmentB = uuid(902)

    static let assignee = Participant(
        id: uuid(910),
        displayName: "서연",
        linkedUserID: nil,
        speakerLabel: nil
    )
    static let bystander = Participant(
        id: uuid(911),
        displayName: "민준",
        linkedUserID: nil,
        speakerLabel: nil
    )

    /// Deterministic ids in their own namespace, so they can never collide with `TestFixtures`.
    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: "0000000A-0000-0000-0000-\(String(format: "%012d", index))")!
    }

    static let evidenceA = EvidenceReference(
        meetingID: meetingA,
        transcriptSegmentID: segmentA,
        quote: "2월 출시로 가기로 했습니다"
    )

    static let evidenceB = EvidenceReference(
        meetingID: meetingB,
        transcriptSegmentID: segmentB,
        quote: "지표 정의는 다음에 이야기합시다"
    )

    // MARK: - Meetings

    /// `startTime` is a parameter because a quote's timestamp is only shown when the transcript
    /// really has one — pasted text has none at all.
    static func meeting(
        id: UUID = meetingA,
        inProject projectID: UUID = projectA,
        segmentID: UUID = segmentA,
        startTime: TimeInterval? = 65,
        participants: [Participant] = [assignee, bystander]
    ) -> Meeting {
        Meeting(
            id: id,
            projectID: projectID,
            title: "Kickoff",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: [
                TranscriptSegment(
                    id: segmentID,
                    meetingID: id,
                    speakerID: participants.first?.id,
                    text: "2월 출시로 가기로 했습니다",
                    startTime: startTime,
                    endTime: startTime.map { $0 + 5 }
                )
            ],
            createdAt: TestFixtures.fixedDate
        )
    }

    // MARK: - Work state

    static func decision(
        id: UUID,
        inProject projectID: UUID = projectA,
        fromMeeting meetingID: UUID = meetingA,
        statement: String = "2월 출시로 진행한다",
        status: DecisionStatus = .proposed,
        evidence: EvidenceReference? = evidenceA,
        createdAt: Date = TestFixtures.fixedDate,
        updatedAt: Date = TestFixtures.fixedDate
    ) -> Decision {
        Decision(
            id: id,
            projectID: projectID,
            meetingID: meetingID,
            statement: statement,
            rationale: nil,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.8),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func actionItem(
        id: UUID,
        inProject projectID: UUID = projectA,
        fromMeeting meetingID: UUID = meetingA,
        title: String = "지표 정의 초안 작성",
        assigneeID: UUID? = nil,
        dueDate: Date? = nil,
        status: ActionItemStatus = .proposed,
        evidence: EvidenceReference? = evidenceA,
        createdAt: Date = TestFixtures.fixedDate,
        updatedAt: Date = TestFixtures.fixedDate
    ) -> ActionItem {
        ActionItem(
            id: id,
            projectID: projectID,
            meetingID: meetingID,
            title: title,
            details: nil,
            assigneeID: assigneeID,
            dueDate: dueDate,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.7),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func openQuestion(
        id: UUID,
        inProject projectID: UUID = projectA,
        fromMeeting meetingID: UUID = meetingA,
        question: String = "지표 정의는 누가 확정하는가?",
        status: OpenQuestionStatus = .open,
        evidence: EvidenceReference? = evidenceA,
        createdAt: Date = TestFixtures.fixedDate,
        reviewedAt: Date? = nil
    ) -> OpenQuestion {
        OpenQuestion(
            id: id,
            projectID: projectID,
            meetingID: meetingID,
            question: question,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.6),
            createdAt: createdAt,
            resolvedAt: status == .resolved ? TestFixtures.laterDate : nil,
            reviewedAt: reviewedAt
        )
    }

    /// `sourceMeetingID` is optional here for the same reason it is optional on the model: an
    /// agenda item a person added by hand belongs to no meeting.
    static func agendaItem(
        id: UUID,
        inProject projectID: UUID = projectA,
        fromMeeting sourceMeetingID: UUID? = meetingA,
        title: String = "지표 정의 확정",
        status: AgendaItemStatus = .pending,
        evidence: EvidenceReference? = evidenceA,
        createdAt: Date = TestFixtures.fixedDate,
        reviewedAt: Date? = nil
    ) -> AgendaItem {
        AgendaItem(
            id: id,
            projectID: projectID,
            title: title,
            reason: "이번 회의에서 결론이 나지 않음",
            sourceMeetingID: sourceMeetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: status,
            createdAt: createdAt,
            evidence: evidence,
            confidence: evidence == nil ? nil : Confidence(0.5),
            reviewedAt: reviewedAt
        )
    }

    static func project(
        id: UUID = projectA,
        meetings: [Meeting]? = nil,
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        nextAgenda: [AgendaItem] = []
    ) -> Project {
        Project(
            id: id,
            name: "HAE.NA",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: meetings ?? [
                meeting(),
                meeting(id: meetingB, segmentID: segmentB, startTime: 3_612)
            ],
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            nextAgenda: nextAgenda
        )
    }
}
