import Foundation

/// One AI-proposed item awaiting a person's verdict, flattened across the four domain types so a
/// single review list can show them together.
///
/// A presentation-layer view onto the domain models, not a replacement for them: it carries the
/// original value in its payload, and nothing is stored in this shape.
enum WorkStateProposal: Identifiable, Equatable, Sendable {
    case decision(Decision)
    case actionItem(ActionItem)
    case openQuestion(OpenQuestion)
    case agendaItem(AgendaItem)

    enum Kind: String, Equatable, Sendable, CaseIterable {
        case decision
        case actionItem
        case openQuestion
        case agendaItem
    }

    var id: UUID {
        switch self {
        case .decision(let value): return value.id
        case .actionItem(let value): return value.id
        case .openQuestion(let value): return value.id
        case .agendaItem(let value): return value.id
        }
    }

    var kind: Kind {
        switch self {
        case .decision: return .decision
        case .actionItem: return .actionItem
        case .openQuestion: return .openQuestion
        case .agendaItem: return .agendaItem
        }
    }

    /// The main line to show.
    var headline: String {
        switch self {
        case .decision(let value): return value.statement
        case .actionItem(let value): return value.title
        case .openQuestion(let value): return value.question
        case .agendaItem(let value): return value.title
        }
    }

    /// A secondary line, when the model supplied one. Nil rather than an empty string so callers
    /// omit the row entirely instead of rendering a blank.
    var supporting: String? {
        switch self {
        case .decision(let value): return value.rationale
        case .actionItem(let value): return value.details
        case .openQuestion: return nil
        case .agendaItem(let value): return value.reason
        }
    }

    var confidence: Confidence? {
        switch self {
        case .decision(let value): return value.confidence
        case .actionItem(let value): return value.confidence
        case .openQuestion(let value): return value.confidence
        case .agendaItem(let value): return value.confidence
        }
    }

    /// The transcript quote behind this suggestion. Every AI-derived proposal has one — evidence is
    /// what got it past validation in the first place.
    var evidence: EvidenceReference? {
        switch self {
        case .decision(let value): return value.evidence
        case .actionItem(let value): return value.evidence
        case .openQuestion(let value): return value.evidence
        case .agendaItem(let value): return value.evidence
        }
    }

    var createdAt: Date {
        switch self {
        case .decision(let value): return value.createdAt
        case .actionItem(let value): return value.createdAt
        case .openQuestion(let value): return value.createdAt
        case .agendaItem(let value): return value.createdAt
        }
    }

    /// The meeting this came out of, using each type's own direct link. Optional because an agenda
    /// item is allowed to belong to no meeting — one a user added by hand has no source — and
    /// naming an arbitrary meeting for it would be worse than naming none.
    var meetingID: UUID? {
        switch self {
        case .decision(let value): return value.meetingID
        case .actionItem(let value): return value.meetingID
        case .openQuestion(let value): return value.meetingID
        case .agendaItem(let value): return value.sourceMeetingID
        }
    }
}

/// Selects the work state that still needs a person's attention, and the work state that has
/// already been through review.
///
/// "Still needs attention" is `PendingAIProposalPolicy.isPending` — the same predicate
/// `WorkStateExtractionService` uses to decide what a re-extraction replaces, so a proposal is
/// never shown here without also being subject to replacement, or vice versa.
enum WorkStateInbox {
    static func pendingProposals(in project: Project) -> [WorkStateProposal] {
        var proposals: [WorkStateProposal] = []

        proposals += project.decisions
            .filter { PendingAIProposalPolicy.isPending($0) }
            .map(WorkStateProposal.decision)

        proposals += project.actionItems
            .filter { PendingAIProposalPolicy.isPending($0) }
            .map(WorkStateProposal.actionItem)

        proposals += project.openQuestions
            .filter { PendingAIProposalPolicy.isPending($0) }
            .map(WorkStateProposal.openQuestion)

        proposals += project.nextAgenda
            .filter { PendingAIProposalPolicy.isPending($0) }
            .map(WorkStateProposal.agendaItem)

        return proposals.sorted(by: isOrderedBefore)
    }

    /// Grouped by kind, then oldest first, then by id — a total order, so the list never reshuffles
    /// between reads of the same data.
    static func isOrderedBefore(_ lhs: WorkStateProposal, _ rhs: WorkStateProposal) -> Bool {
        if lhs.kind != rhs.kind {
            let order = WorkStateProposal.Kind.allCases
            return (order.firstIndex(of: lhs.kind) ?? 0) < (order.firstIndex(of: rhs.kind) ?? 0)
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Decisions the user confirmed — the project's decision log.
    static func confirmedDecisions(in project: Project) -> [Decision] {
        project.decisions
            .filter { $0.status == .confirmed }
            .sorted(by: isOrderedBefore)
    }

    /// Work the user accepted and has not finished or cancelled.
    static func activeActionItems(in project: Project) -> [ActionItem] {
        project.actionItems
            .filter { $0.status == .confirmed || $0.status == .inProgress }
            .sorted(by: isOrderedBefore)
    }

    /// Questions a person has seen and left open.
    static func reviewedOpenQuestions(in project: Project) -> [OpenQuestion] {
        project.openQuestions
            .filter { $0.status == .open && $0.reviewedAt != nil }
            .sorted(by: isOrderedBefore)
    }

    /// Agenda entries a person kept for the next meeting.
    static func reviewedAgendaItems(in project: Project) -> [AgendaItem] {
        project.nextAgenda
            .filter { $0.status == .pending && $0.reviewedAt != nil }
            .sorted(by: isOrderedBefore)
    }

    /// Most recently touched first, then by id — a total order. Named rather than inlined for the
    /// same reason as the two below: a screen that narrows these to one meeting, or merges them
    /// across projects, has to re-sort the result, and doing that with a second, hand-copied
    /// comparator is how two lists of the same thing start disagreeing.
    static func isOrderedBefore(_ lhs: Decision, _ rhs: Decision) -> Bool {
        (lhs.updatedAt, lhs.id.uuidString) > (rhs.updatedAt, rhs.id.uuidString)
    }

    static func isOrderedBefore(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        (lhs.updatedAt, lhs.id.uuidString) > (rhs.updatedAt, rhs.id.uuidString)
    }

    /// Newest first, then by id — a total order.
    static func isOrderedBefore(_ lhs: OpenQuestion, _ rhs: OpenQuestion) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) > (rhs.createdAt, rhs.id.uuidString)
    }

    static func isOrderedBefore(_ lhs: AgendaItem, _ rhs: AgendaItem) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) > (rhs.createdAt, rhs.id.uuidString)
    }
}
