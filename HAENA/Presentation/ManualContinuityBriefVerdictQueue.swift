import Foundation

/// The one verdict pair the existing `WorkStateTransitionReviewService` accepts for a candidate,
/// named by what approving it really does to the Project. Derived from the proposal's finite
/// `transitionKind` (and, for `.delayed`, the Brief's typed delay kind); no case exists that the
/// service cannot apply, and no text is interpreted to pick one.
enum ManualContinuityBriefVerdictKind: Equatable, Sendable {
    /// `applyCompleted`: the approved prior item becomes `.completed`.
    case completion
    /// `applyDelayed`: the prior item's status and due date stay as they are; only this meeting's
    /// duplicate candidate is cleared. Blocked, deferred and overdue keep their distinct label.
    case progress(ManualContinuityBriefDelayKind)
    /// `applyChanged`: the approved prior item takes this meeting's content.
    case change
    /// `applyResolved`: the open question is marked resolved and its linked item approved.
    case resolution
    /// `approveCurrent`: this meeting's item is approved as a new object.
    case adoption
    /// `consumeSame`: the duplicate from this meeting is removed; the prior item is untouched.
    case duplicate

    init(_ transition: ManualContinuityBriefTransition, delayKind: ManualContinuityBriefDelayKind?) {
        switch transition.proposal.transitionKind {
        case .completed: self = .completion
        case .delayed: self = .progress(delayKind ?? .deferred)
        case .changed: self = .change
        case .resolved: self = .resolution
        case .new: self = .adoption
        case .same: self = .duplicate
        }
    }

    /// Primary button. Every string names the real effect; "acknowledge" verdicts say what stays.
    var approveKey: String {
        switch self {
        case .completion: "완료로 반영"
        case .progress(.blocked): "차단 확인 · 상태 유지"
        case .progress(.deferred): "지연 확인 · 상태 유지"
        case .progress(.overdue): "기한 초과 확인 · 기한 유지"
        case .change: "변경 반영"
        case .resolution: "해결로 반영"
        case .adoption: "새 항목 승인"
        case .duplicate: "중복 정리"
        }
    }

    var rejectKey: String {
        switch self {
        case .completion: "완료 후보 거절"
        case .progress: "진행 후보 거절"
        case .change: "변경 거절"
        case .resolution: "해결 거절"
        case .adoption: "새 항목 거절"
        case .duplicate: "중복 거절"
        }
    }

    /// What the Project looks like after approval, in words, so the user can tell before pressing.
    var approveEffectKey: String {
        switch self {
        case .completion: "기존 항목을 완료로 표시합니다."
        case .progress: "기존 항목의 상태와 기한은 그대로 두고 이번 회의 후보만 정리합니다."
        case .change: "기존 항목 내용을 이번 회의 내용으로 갱신합니다."
        case .resolution: "질문을 해결로 표시하고 연결된 항목을 승인합니다."
        case .adoption: "이번 회의 항목을 새 항목으로 승인합니다."
        case .duplicate: "이번 회의 중복 후보를 정리하고 기존 항목을 유지합니다."
        }
    }
}

/// Why the candidate section is empty — three different facts that must not share one sentence.
enum ManualContinuityBriefCandidateState: Equatable, Sendable {
    /// The transition store could not be read. Not zero.
    case unavailable
    /// Fewer than two meetings: there is no earlier state to compare, so nothing can be pending.
    case firstBrief
    /// Two or more meetings and nothing awaiting a verdict.
    case none
    case pending(Int)
}

/// The Brief split into the three things a user has to tell apart: what they already approved,
/// what this meeting asks them to decide, and the next agenda they already approved. A pure
/// function of the loaded read model; it never reads a repository and holds no verdict.
struct ManualContinuityBriefVerdictQueue: Equatable, Sendable {
    struct TransitionCandidate: Equatable, Sendable, Identifiable {
        let transition: ManualContinuityBriefTransition
        let verdict: ManualContinuityBriefVerdictKind
        /// Present only for a `.progress` verdict.
        let delay: ManualContinuityBriefDelayItem?
        var id: UUID { transition.proposal.id }
    }

    // A — already approved, read-only here.
    let carried: ManualContinuityBrief
    // B — awaiting an explicit verdict, each with its own exact ID.
    let completions: [TransitionCandidate]
    let progress: [TransitionCandidate]
    let changes: [TransitionCandidate]
    let links: [ManualContinuityBriefAmbiguousMatch]
    let agendaCandidates: [ManualContinuityBriefAgendaCandidate]
    // C — approved next agenda, read-only here.
    let approvedAgenda: [AgendaItem]
    let state: ManualContinuityBriefCandidateState

    var candidateCount: Int {
        completions.count + progress.count + changes.count + links.count + agendaCandidates.count
    }

    /// Every pending transition candidate, in section order, for isolation checks.
    var transitionCandidates: [TransitionCandidate] { completions + progress + changes }

    init(brief: ManualContinuityBrief) {
        carried = brief
        let delayByID = Dictionary(uniqueKeysWithValues: brief.delayedOrBlockedItems.map { ($0.transition.proposal.id, $0) })
        let linkIDs = Set(brief.ambiguousMatches.flatMap { $0.selections.compactMap(\.transitionID) })
        let plainAgendaIDs = Set(brief.agendaCandidates.flatMap { candidate in
            candidate.sources.compactMap { $0.kind == .pendingAgendaItem ? $0.transitionID : nil }
        })
        var completions: [TransitionCandidate] = [], progress: [TransitionCandidate] = [], changes: [TransitionCandidate] = []
        for transition in brief.pendingTransitions {
            let id = transition.proposal.id
            if let delay = delayByID[id] {
                progress.append(.init(transition: transition, verdict: .progress(delay.kind), delay: delay))
            } else if linkIDs.contains(id) || plainAgendaIDs.contains(id) {
                continue // owned by a link group or an agenda candidate row
            } else if transition.proposal.transitionKind == .completed {
                completions.append(.init(transition: transition, verdict: .completion, delay: nil))
            } else {
                changes.append(.init(transition: transition, verdict: .init(transition, delayKind: nil), delay: nil))
            }
        }
        // Keep the Brief's own blocked → overdue → deferred priority.
        progress.sort { lhs, rhs in
            let order = brief.delayedOrBlockedItems.map(\.transition.proposal.id)
            return (order.firstIndex(of: lhs.id) ?? 0) < (order.firstIndex(of: rhs.id) ?? 0)
        }
        self.completions = completions
        self.progress = progress
        self.changes = changes
        links = brief.ambiguousMatches
        agendaCandidates = brief.agendaCandidates
        approvedAgenda = brief.approvedNextAgenda
        let count = completions.count + progress.count + changes.count + brief.ambiguousMatches.count + brief.agendaCandidates.count
        if count > 0 { state = .pending(count) }
        else if brief.transitionAvailability == .unavailable { state = .unavailable }
        else if brief.project.meetings.count < 2 { state = .firstBrief }
        else { state = .none }
    }
}
