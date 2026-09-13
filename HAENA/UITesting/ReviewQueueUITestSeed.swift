#if DEBUG
import Foundation

/// Finite opt-in fixture, not a provider or environment payload adapter.
enum ReviewQueueUITestSeed {
    /// `evidence` extends `queue` with two more stored segments in the review meeting: one with
    /// text identical to the referenced segment, and one the agenda proposal alone points at. It
    /// exists so a test can tell exact-ID navigation apart from text matching.
    enum Scenario: String { case queue, empty, missingSource, evidence }
    static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "CC000000-0000-4000-8000-%012d", suffix))!
    }
    static func select(environment: [String: String]) -> Project? {
        guard environment["HAENA_UI_TESTING"] == "1",
              let raw = environment["HAENA_UI_TEST_REVIEW_QUEUE"],
              let scenario = Scenario(rawValue: raw) else { return nil }
        return project(scenario)
    }
    static func project(_ scenario: Scenario = .queue) -> Project {
        let date = Date(timeIntervalSince1970: 1_786_358_400)
        let person = Participant(id: id(6), displayName: "Synthetic Reviewer", linkedUserID: nil, speakerLabel: "A")
        let segment = TranscriptSegment(id: id(4), meetingID: id(2), speakerID: person.id,
            sourceSpeakerLabel: "A", text: "Synthetic exact source quote.", startTime: 65, endTime: 70)
        let meeting = Meeting(id: id(2), projectID: id(1), title: "Synthetic Review Meeting", occurredAt: date,
            sourceType: .audioFile, participants: [person], transcriptSegments: [segment], createdAt: date)
        let otherSegment = TranscriptSegment(id: id(5), meetingID: id(3), speakerID: nil,
            sourceSpeakerLabel: nil, text: "Synthetic other source.", startTime: nil, endTime: nil)
        let other = Meeting(id: id(3), projectID: id(1), title: "Synthetic Earlier Meeting", occurredAt: date.addingTimeInterval(-60),
            sourceType: .pastedText, participants: [], transcriptSegments: [otherSegment], createdAt: date)
        let evidence = EvidenceReference(meetingID: meeting.id, transcriptSegmentID: segment.id, quote: segment.text)
        let decision = Decision(id: id(100), projectID: id(1), meetingID: meeting.id, statement: "Synthetic pending decision",
            rationale: "Synthetic rationale", status: .proposed, evidence: evidence, confidence: Confidence(0.8), createdAt: date, updatedAt: date)
        let action = ActionItem(id: id(101), projectID: id(1), meetingID: meeting.id, title: "Synthetic pending action",
            details: "Synthetic details", assigneeID: person.id, dueDate: date, status: .proposed,
            evidence: evidence, confidence: Confidence(0.7), createdAt: date, updatedAt: date)
        let question = OpenQuestion(id: id(102), projectID: id(1), meetingID: meeting.id, question: "Synthetic pending question",
            status: .open, evidence: evidence, confidence: Confidence(0.6), createdAt: date)
        let agenda = AgendaItem(id: id(103), projectID: id(1), title: "Synthetic pending agenda", reason: "Synthetic agenda reason",
            sourceMeetingID: meeting.id, relatedActionItemID: nil, relatedOpenQuestionID: nil, status: .pending,
            createdAt: date, evidence: evidence, confidence: Confidence(0.5))
        let otherAction = ActionItem(id: id(104), projectID: id(1), meetingID: other.id, title: action.title,
            status: .proposed, evidence: .init(meetingID: other.id, transcriptSegmentID: otherSegment.id, quote: otherSegment.text),
            confidence: Confidence(0.4), createdAt: date, updatedAt: date)
        var approvedDecision = Decision(id: id(200), projectID: id(1), meetingID: meeting.id, statement: "Synthetic approved decision",
            status: .confirmed, evidence: evidence, confidence: .maximum, createdAt: date, updatedAt: date)
        approvedDecision.rationale = nil
        let approvedAction = ActionItem(id: id(201), projectID: id(1), meetingID: meeting.id, title: "Synthetic approved action",
            status: .confirmed, evidence: evidence, confidence: .maximum, createdAt: date, updatedAt: date)
        let approvedQuestion = OpenQuestion(id: id(202), projectID: id(1), meetingID: meeting.id, question: "Synthetic approved question",
            status: .open, evidence: evidence, confidence: .maximum, createdAt: date, reviewedAt: date)
        let approvedAgenda = AgendaItem(id: id(203), projectID: id(1), title: "Synthetic approved agenda", reason: "Synthetic approved reason",
            sourceMeetingID: meeting.id, relatedActionItemID: nil, relatedOpenQuestionID: nil, status: .pending,
            createdAt: date, evidence: evidence, confidence: .maximum, reviewedAt: date)
        var project = Project(id: id(1), name: "Synthetic Review Project", summary: "", createdAt: date, updatedAt: date,
            meetings: [meeting, other], decisions: [approvedDecision], actionItems: [approvedAction],
            openQuestions: [approvedQuestion], nextAgenda: [approvedAgenda])
        if scenario != .empty {
            project.decisions.append(decision); project.actionItems += [action, otherAction]
            project.openQuestions.append(question); project.nextAgenda.append(agenda)
        }
        if scenario == .missingSource { project.meetings[0].transcriptSegments = [] }
        if scenario == .evidence {
            let duplicate = TranscriptSegment(id: id(8), meetingID: id(2), speakerID: person.id,
                sourceSpeakerLabel: "A", text: segment.text, startTime: 5, endTime: 10)
            let second = TranscriptSegment(id: id(7), meetingID: id(2), speakerID: person.id,
                sourceSpeakerLabel: "A", text: "Synthetic second source quote.", startTime: 125, endTime: 130)
            project.meetings[0].transcriptSegments = [duplicate, segment, second]
            project.nextAgenda[1].evidence = EvidenceReference(meetingID: meeting.id, transcriptSegmentID: second.id, quote: second.text)
        }
        return project
    }
}
#endif
