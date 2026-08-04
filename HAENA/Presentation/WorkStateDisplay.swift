import Foundation

/// Korean display copy for work-state values. Kept out of the domain enums so the models stay free
/// of presentation concerns, matching `MeetingSourceTypeDisplay`.
enum WorkStateDisplay {
    static func label(for kind: WorkStateProposal.Kind) -> String {
        switch kind {
        case .decision:
            return "결정"
        case .actionItem:
            return "업무"
        case .openQuestion:
            return "미해결 질문"
        case .agendaItem:
            return "다음 아젠다"
        }
    }

    static func label(for status: DecisionStatus) -> String {
        switch status {
        case .proposed:
            return "제안됨"
        case .confirmed:
            return "확정"
        case .superseded:
            return "대체됨"
        case .rejected:
            return "제외됨"
        }
    }

    static func label(for status: ActionItemStatus) -> String {
        switch status {
        case .proposed:
            return "제안됨"
        case .confirmed:
            return "확정"
        case .inProgress:
            return "진행 중"
        case .completed:
            return "완료"
        case .cancelled:
            return "제외됨"
        }
    }

    static func label(for status: OpenQuestionStatus) -> String {
        switch status {
        case .open:
            return "미해결"
        case .resolved:
            return "해결됨"
        case .dismissed:
            return "제외됨"
        }
    }

    static func label(for status: AgendaItemStatus) -> String {
        switch status {
        case .pending:
            return "예정"
        case .resolved:
            return "처리됨"
        case .dismissed:
            return "제외됨"
        }
    }

    /// Confidence as a whole percentage. Returns nil when there is none to show — a user-added item
    /// has no model confidence, and inventing "0%" for it would read as the model being certain it
    /// is wrong.
    static func confidenceLabel(_ confidence: Confidence?) -> String? {
        guard let confidence else {
            return nil
        }
        return "확신도 \(Int((confidence.value * 100).rounded()))%"
    }

    /// Nil when no due date is set, so callers omit the field rather than printing "미지정" in a
    /// place where a date is expected.
    static func dueDateLabel(_ dueDate: Date?, formatter: MeetingDateFormatter = MeetingDateFormatter()) -> String? {
        guard let dueDate else {
            return nil
        }
        return "마감 \(formatter.dateOnlyString(from: dueDate))"
    }

    static func assigneeLabel(_ assigneeID: UUID?, participants: [Participant]) -> String {
        guard let assigneeID,
              let participant = participants.first(where: { $0.id == assigneeID }) else {
            return "담당자 미지정"
        }
        return "담당 \(participant.displayName)"
    }
}
