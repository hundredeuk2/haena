import Foundation

/// UI-only adapter: legacy display values used by exports remain unchanged.
@MainActor
enum UIWorkStateDisplay {
    static func label(for kind: WorkStateProposal.Kind) -> String { L10n.text(WorkStateDisplay.label(for: kind)) }
    static func label(for status: DecisionStatus) -> String { L10n.text(WorkStateDisplay.label(for: status)) }
    static func label(for status: ActionItemStatus) -> String { L10n.text(WorkStateDisplay.label(for: status)) }
    static func label(for status: OpenQuestionStatus) -> String { L10n.text(WorkStateDisplay.label(for: status)) }
    static func label(for status: AgendaItemStatus) -> String { L10n.text(WorkStateDisplay.label(for: status)) }
    static func confidenceLabel(_ confidence: Confidence?) -> String? {
        confidence.map { L10n.format("확신도 %@%%", String(Int(($0.value * 100).rounded()))) }
    }
    static func dueDateLabel(_ date: Date?, formatter: MeetingDateFormatter? = nil) -> String? {
        let display = formatter ?? MeetingDateFormatter(locale: AppLanguageSettings.shared.locale)
        return date.map { L10n.format("마감 %@", display.dateOnlyString(from: $0)) }
    }
    static func assigneeLabel(_ id: UUID?, participants: [Participant]) -> String {
        guard let name = WorkStateDisplay.assigneeName(id, participants: participants) else { return L10n.text("담당자 미지정") }
        return L10n.format("담당 %@", name)
    }
    static func assigneeName(_ id: UUID?, participants: [Participant]) -> String? {
        WorkStateDisplay.assigneeName(id, participants: participants)
    }
}

@MainActor
enum UIMeetingCountDisplay {
    static func label(count: Int) -> String { L10n.format("회의 %@개", String(count)) }
}

@MainActor
enum UIMeetingReanalysisCopy {
    static var button: String { L10n.text(MeetingReanalysisCopy.button) }
    static var availability: String { L10n.text(MeetingReanalysisCopy.availability) }
    static func refusal(_ reason: MeetingReanalysisEligibility) -> String { L10n.text(MeetingReanalysisCopy.refusal(reason)) }
}
