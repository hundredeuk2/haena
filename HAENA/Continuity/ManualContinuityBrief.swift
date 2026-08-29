import Foundation

enum ManualContinuityBriefLoadResult: Equatable, Sendable {
    case loaded(ManualContinuityBrief)
    case projectNotFound
    case projectUnavailable
}

enum ManualContinuityBriefPersonalisation: String, Equatable, Sendable {
    case personalised
    case notConfigured
    case unavailable
}

enum ManualContinuityBriefTransitionAvailability: String, Equatable, Sendable {
    case available
    case unavailable
}

struct ManualContinuityBriefWarning: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case profileUnavailable
        case transitionsUnavailable
        case danglingEvidence
        case missingRequiredEvidence
    }

    let kind: Kind
    /// Present only when the warning belongs to one transition. No free-form error is retained.
    let transitionID: UUID?
}

/// A complete domain value resolved from a transition id. Keeping the original value, rather than
/// reducing it to display text, lets future presentation layers show additional fields without a
/// second repository read.
enum ManualContinuityBriefWorkState: Equatable, Sendable {
    case decision(Decision)
    case actionItem(ActionItem)
    case openQuestion(OpenQuestion)
    case agendaItem(AgendaItem)

    var id: UUID {
        switch self {
        case .decision(let value): return value.id
        case .actionItem(let value): return value.id
        case .openQuestion(let value): return value.id
        case .agendaItem(let value): return value.id
        }
    }

    var kind: WorkStateKind {
        switch self {
        case .decision: return .decision
        case .actionItem: return .actionItem
        case .openQuestion: return .openQuestion
        case .agendaItem: return .agendaItem
        }
    }

    var displayText: String {
        switch self {
        case .decision(let value): return value.statement
        case .actionItem(let value): return value.title
        case .openQuestion(let value): return value.question
        case .agendaItem(let value): return value.title
        }
    }

    var evidenceReference: EvidenceReference? {
        switch self {
        case .decision(let value): return value.evidence
        case .actionItem(let value): return value.evidence
        case .openQuestion(let value): return value.evidence
        case .agendaItem(let value): return value.evidence
        }
    }

    var dueDate: Date? {
        guard case .actionItem(let value) = self else { return nil }
        return value.dueDate
    }
}

struct ManualContinuityBriefEvidenceSegment: Equatable, Sendable {
    let meetingID: UUID
    let meetingTitle: String
    let transcriptSegmentID: UUID
    let text: String
}

enum ManualContinuityBriefDanglingEvidenceReason: String, Equatable, Sendable {
    case missingMeeting
    case missingSegment
    case quoteNotInSegment
}

enum ManualContinuityBriefEvidenceState: Equatable, Sendable {
    /// Normal for a user-entered prior object and for an overdue-date transition.
    case notRequired
    case resolved(ManualContinuityBriefEvidenceSegment)
    case dangling(ManualContinuityBriefDanglingEvidenceReason)
}

enum ManualContinuityBriefApplyBlockReason: String, Equatable, Sendable {
    case danglingEvidence
    case missingRequiredEvidence
}

enum ManualContinuityBriefDestructiveApplyState: Equatable, Sendable {
    /// A reviewed row retained by a caller outside the pending section has no pending action.
    case notApplicable
    case enabled
    case disabled(ManualContinuityBriefApplyBlockReason)
}

struct ManualContinuityBriefTransition: Equatable, Sendable {
    let proposal: WorkStateTransitionProposal
    let previousState: ManualContinuityBriefWorkState?
    let currentState: ManualContinuityBriefWorkState?
    let sourceMeetingTitle: String?
    let sourceMeetingOccurredAt: Date?
    let relevantDueDate: Date?
    let evidence: ManualContinuityBriefEvidenceState
    let destructiveApplyState: ManualContinuityBriefDestructiveApplyState
}

enum ManualContinuityBriefDelayKind: String, Equatable, Sendable {
    case deferred
    case blocked
    case overdue
}

struct ManualContinuityBriefDelayItem: Equatable, Sendable {
    let kind: ManualContinuityBriefDelayKind
    let actionItem: ActionItem?
    /// Resolved locally from the Project's participant rosters. Nil means unassigned or an
    /// unresolved participant id; the read model never guesses from the local-user profile.
    let assigneeDisplayName: String?
    let transition: ManualContinuityBriefTransition
}

struct ManualContinuityBriefAgendaCandidateSource: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case pendingAgendaItem
        case carriedToAgenda
    }

    let kind: Kind
    let transitionID: UUID?
    let evidence: ManualContinuityBriefEvidenceState
    let destructiveApplyState: ManualContinuityBriefDestructiveApplyState
}

struct ManualContinuityBriefAgendaCandidate: Equatable, Sendable {
    let agendaItem: AgendaItem
    /// All typed reasons this item is a candidate. Multiple carried relations are preserved rather
    /// than collapsed into one unexplained boolean.
    let sources: [ManualContinuityBriefAgendaCandidateSource]
}

struct ManualContinuityBriefAmbiguousMatch: Equatable, Sendable {
    let group: WorkStateAmbiguousMatchGroup
    let incomingState: ManualContinuityBriefWorkState?
    let priorCandidates: [ManualContinuityBriefWorkState]
    /// Every finite selection the review service accepts, with the exact evidence/apply safety
    /// already resolved. Presentation code must not re-read Project transcripts or guess which
    /// sibling transition belongs to a prior candidate.
    let selections: [ManualContinuityBriefAmbiguitySelection]
}

struct ManualContinuityBriefAmbiguitySelection: Equatable, Sendable {
    let selection: WorkStateAmbiguousMatchSelection
    let priorState: ManualContinuityBriefWorkState?
    /// Present for a prior-candidate choice when its sibling transition still exists. `.new` is a
    /// group-level choice and intentionally has no transition id.
    let transitionID: UUID?
    let evidence: ManualContinuityBriefEvidenceState
    let destructiveApplyState: ManualContinuityBriefDestructiveApplyState
}

struct ManualContinuityBrief: Equatable, Sendable {
    let project: Project
    let personalisation: ManualContinuityBriefPersonalisation
    let transitionAvailability: ManualContinuityBriefTransitionAvailability
    let warnings: [ManualContinuityBriefWarning]
    let confirmedDecisions: [Decision]
    let myActiveCommitments: [ActionItem]
    let otherCommitments: [ActionItem]
    /// User-owned terminal state is useful briefing context but is never active work or an agenda
    /// candidate. A pending model proposal cannot enter this section because `.proposed` is a
    /// different finite status.
    let completedCommitments: [ActionItem]
    let pendingTransitions: [ManualContinuityBriefTransition]
    let delayedOrBlockedItems: [ManualContinuityBriefDelayItem]
    let unresolvedQuestions: [OpenQuestion]
    let approvedNextAgenda: [AgendaItem]
    let agendaCandidates: [ManualContinuityBriefAgendaCandidate]
    let ambiguousMatches: [ManualContinuityBriefAmbiguousMatch]
}

/// Read-only composition of Project, continuity transitions, and the local profile.
///
/// This service never calls a save/upsert/delete method and never re-runs the transition engine.
/// Repository error descriptions are intentionally dropped at their boundary.
struct ManualContinuityBriefService: Sendable {
    let projects: any ProjectRepository
    let transitions: any WorkStateTransitionRepository
    let profiles: any LocalUserProfileRepository

    func load(projectID: UUID) async -> ManualContinuityBriefLoadResult {
        let project: Project
        do {
            guard let loaded = try await projects.project(id: projectID), loaded.id == projectID else {
                return .projectNotFound
            }
            project = loaded
        } catch {
            return .projectUnavailable
        }

        let profile: LocalUserProfile?
        let personalisation: ManualContinuityBriefPersonalisation
        var warnings: [ManualContinuityBriefWarning] = []
        do {
            profile = try await profiles.profile()
            personalisation = MyWorkPolicy.isPersonalised(profile) ? .personalised : .notConfigured
        } catch {
            profile = nil
            personalisation = .unavailable
            warnings.append(.init(kind: .profileUnavailable, transitionID: nil))
        }

        var transitionRows: [WorkStateTransitionProposal] = []
        var ambiguityRows: [WorkStateAmbiguousMatchGroup] = []
        var transitionAvailability: ManualContinuityBriefTransitionAvailability = .unavailable
        do {
            transitionRows = try await transitions.proposals(forProject: projectID)
            let groups = try await transitions.ambiguousMatchGroups(forProject: projectID)
            var unresolvedGroups: [WorkStateAmbiguousMatchGroup] = []
            for group in groups {
                if try await transitions.ambiguityReview(groupID: group.id) == nil {
                    unresolvedGroups.append(group)
                }
            }
            ambiguityRows = unresolvedGroups
            transitionAvailability = .available
        } catch {
            transitionRows = []
            ambiguityRows = []
            transitionAvailability = .unavailable
            warnings.append(.init(kind: .transitionsUnavailable, transitionID: nil))
        }

        let confirmedDecisions = project.decisions
            .filter(ApprovedWorkStatePolicy.isApproved)
            .sorted(by: Self.decisionOrder)
        let activeCommitments = project.actionItems
            .filter(ApprovedWorkStatePolicy.isApproved)
            .sorted(by: Self.actionItemOrder)
        let myActiveCommitments: [ActionItem]
        let otherCommitments: [ActionItem]
        if personalisation == .personalised {
            myActiveCommitments = activeCommitments.filter { MyWorkPolicy.isMine($0, profile: profile) }
            otherCommitments = activeCommitments.filter { !MyWorkPolicy.isMine($0, profile: profile) }
        } else {
            // Without an identified profile no item may be labelled "mine".
            myActiveCommitments = []
            otherCommitments = activeCommitments
        }
        let completedCommitments = project.actionItems
            .filter { $0.projectID == project.id && $0.status == .completed }
            .sorted(by: Self.actionItemOrder)

        let unresolvedQuestions = project.openQuestions
            .filter(ApprovedWorkStatePolicy.isApproved)
            .sorted(by: Self.openQuestionOrder)
        let approvedNextAgenda = project.nextAgenda
            .filter(ApprovedWorkStatePolicy.isApproved)
            .sorted(by: Self.agendaOrder)

        let pendingTransitions = transitionRows
            .filter { $0.reviewStatus == .pendingReview }
            .filter { !Self.isAlreadyDecided($0, in: project) }
            .map { Self.transition($0, in: project) }
            .sorted(by: Self.transitionOrder)
        for row in pendingTransitions {
            switch row.evidence {
            case .dangling:
                warnings.append(.init(kind: .danglingEvidence, transitionID: row.proposal.id))
            case .notRequired where row.destructiveApplyState == .disabled(.missingRequiredEvidence):
                warnings.append(.init(kind: .missingRequiredEvidence, transitionID: row.proposal.id))
            case .notRequired, .resolved:
                break
            }
        }

        let delays = pendingTransitions.compactMap {
            Self.delayItem($0, in: project)
        }.sorted(by: Self.delayOrder)
        let agendaCandidates = Self.agendaCandidates(
            project: project,
            pendingTransitions: pendingTransitions
        )
        let ambiguousMatches = ambiguityRows.map {
            Self.ambiguousMatch($0, pendingTransitions: pendingTransitions, in: project)
        }.sorted { $0.group.dedupKey < $1.group.dedupKey }

        warnings.sort(by: Self.warningOrder)
        return .loaded(
            ManualContinuityBrief(
                project: project,
                personalisation: personalisation,
                transitionAvailability: transitionAvailability,
                warnings: warnings,
                confirmedDecisions: confirmedDecisions,
                myActiveCommitments: myActiveCommitments,
                otherCommitments: otherCommitments,
                completedCommitments: completedCommitments,
                pendingTransitions: pendingTransitions,
                delayedOrBlockedItems: delays,
                unresolvedQuestions: unresolvedQuestions,
                approvedNextAgenda: approvedNextAgenda,
                agendaCandidates: agendaCandidates,
                ambiguousMatches: ambiguousMatches
            )
        )
    }

    /// Whether a `new` transition has already been settled by a verdict on its object rather than
    /// on the proposal itself.
    ///
    /// A `new` proposal asks one question: adopt this object or not. The AI 제안 inbox answers that
    /// same question against the Project, and it writes only the Project — the transition store
    /// keeps its row `pendingReview` forever. Reading the pending rows alone therefore listed an
    /// approved task under 확정된 상태 and, at the same time, under 검토할 변화 as a 새 항목 후보
    /// with live verdict buttons. The seeded journey could not show this: its two stores agree from
    /// the start, so nothing was ever approved through the inbox first.
    ///
    /// Only `new` is settled this way. Every other kind carries a claim about a *prior* object that
    /// no verdict on the incoming one answers, so those rows stay pending until reviewed here.
    private static func isAlreadyDecided(
        _ proposal: WorkStateTransitionProposal,
        in project: Project
    ) -> Bool {
        guard proposal.transitionKind == .new, let currentID = proposal.currentObjectID else {
            return false
        }
        switch proposal.workStateKind {
        case .decision:
            guard let object = project.decisions.first(where: { $0.id == currentID }) else { return false }
            return !PendingAIProposalPolicy.isPending(object)
        case .actionItem:
            guard let object = project.actionItems.first(where: { $0.id == currentID }) else { return false }
            return !PendingAIProposalPolicy.isPending(object)
        case .openQuestion:
            guard let object = project.openQuestions.first(where: { $0.id == currentID }) else { return false }
            return !PendingAIProposalPolicy.isPending(object)
        case .agendaItem:
            guard let object = project.nextAgenda.first(where: { $0.id == currentID }) else { return false }
            return !PendingAIProposalPolicy.isPending(object)
        }
    }

    // MARK: - Transition resolution

    private static func transition(
        _ proposal: WorkStateTransitionProposal,
        in project: Project
    ) -> ManualContinuityBriefTransition {
        let previous = proposal.previousStateID.flatMap {
            resolve(id: $0, kind: proposal.workStateKind, in: project)
        }
        let current = proposal.currentObjectID.flatMap { id -> ManualContinuityBriefWorkState? in
            if let relation = proposal.relations.first(where: { $0.relatedObjectID == id }) {
                return resolve(id: id, kind: relation.relatedKind, in: project)
            }
            return resolve(id: id, kind: proposal.workStateKind, in: project)
                ?? resolveAny(id: id, in: project)
        }
        // Current Work State evidence is the canonical citation. The pointer is a privacy-safe
        // fallback for transitions such as a structured progress signal whose quote belongs to a
        // different segment than the base object's evidence. A present-but-dangling canonical
        // reference is never hidden by a valid fallback pointer.
        let evidence = current?.evidenceReference.map { evidenceState(for: $0, in: project) }
            ?? evidenceState(for: proposal.evidence, in: project)
        let sourceMeeting = project.meetings.first { $0.id == proposal.sourceMeetingID }
        return ManualContinuityBriefTransition(
            proposal: proposal,
            previousState: previous,
            currentState: current,
            sourceMeetingTitle: sourceMeeting?.title,
            sourceMeetingOccurredAt: sourceMeeting?.occurredAt,
            relevantDueDate: current?.dueDate ?? previous?.dueDate,
            evidence: evidence,
            destructiveApplyState: destructiveApplyState(for: proposal, evidence: evidence)
        )
    }

    private static func delayItem(
        _ transition: ManualContinuityBriefTransition,
        in project: Project
    ) -> ManualContinuityBriefDelayItem? {
        let proposal = transition.proposal
        guard proposal.workStateKind == .actionItem, proposal.transitionKind == .delayed else {
            return nil
        }
        let kind: ManualContinuityBriefDelayKind
        if proposal.basis == .overdueApprovedDueDate {
            kind = .overdue
        } else if proposal.basis == .structuredProgressSignal {
            switch proposal.progressDisposition {
            case .deferred: kind = .deferred
            case .blocked: kind = .blocked
            case nil: return nil
            }
        } else {
            return nil
        }
        let resolvedState = transition.currentState ?? transition.previousState
        let actionItem: ActionItem?
        if case .actionItem(let value)? = resolvedState {
            actionItem = value
        } else {
            actionItem = nil
        }
        return ManualContinuityBriefDelayItem(
            kind: kind,
            actionItem: actionItem,
            assigneeDisplayName: actionItem.flatMap { assigneeDisplayName(for: $0, in: project) },
            transition: transition
        )
    }

    private static func assigneeDisplayName(for actionItem: ActionItem, in project: Project) -> String? {
        guard let assigneeID = actionItem.assigneeID else { return nil }
        if let sourceMeeting = project.meetings.first(where: { $0.id == actionItem.meetingID }),
           let participant = sourceMeeting.participants.first(where: { $0.id == assigneeID }) {
            return participant.displayName
        }
        let meetings = project.meetings.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return uuidOrder($0.id, $1.id)
        }
        return meetings.lazy.compactMap { meeting in
            meeting.participants.first(where: { $0.id == assigneeID })?.displayName
        }.first
    }

    private static func destructiveApplyState(
        for proposal: WorkStateTransitionProposal,
        evidence: ManualContinuityBriefEvidenceState
    ) -> ManualContinuityBriefDestructiveApplyState {
        guard proposal.reviewStatus == .pendingReview else {
            return .notApplicable
        }
        switch evidence {
        case .resolved:
            return .enabled
        case .dangling:
            return .disabled(.danglingEvidence)
        case .notRequired:
            return proposal.basis == .overdueApprovedDueDate
                ? .enabled
                : .disabled(.missingRequiredEvidence)
        }
    }

    // MARK: - Agenda candidates

    /// Candidacy is read from the Project alone, through the same `PendingAIProposalPolicy` the AI
    /// 제안 inbox uses. The two screens have to give one answer, and a transition verdict is not
    /// that answer: rejecting an agenda row writes only the continuity sidecar, so a sidecar-only
    /// verdict would hide an item here that the inbox still offers. The Brief now records agenda
    /// verdicts against the Agenda Item itself, which is what both screens read.
    private static func agendaCandidates(
        project: Project,
        pendingTransitions: [ManualContinuityBriefTransition]
    ) -> [ManualContinuityBriefAgendaCandidate] {
        var sourcesByAgendaID: [UUID: [ManualContinuityBriefAgendaCandidateSource]] = [:]

        for agenda in project.nextAgenda where PendingAIProposalPolicy.isPending(agenda) {
            let reviewTransition = pendingTransitions.first {
                $0.proposal.workStateKind == .agendaItem
                    && $0.proposal.transitionKind == .new
                    && $0.proposal.currentObjectID == agenda.id
            }
            let evidence = reviewTransition?.evidence ?? evidenceState(for: agenda.evidence, in: project)
            sourcesByAgendaID[agenda.id, default: []].append(
                .init(
                    kind: .pendingAgendaItem,
                    transitionID: reviewTransition?.proposal.id,
                    evidence: evidence,
                    destructiveApplyState: reviewTransition?.destructiveApplyState
                        ?? agendaApplyState(evidence: evidence)
                )
            )
        }
        for transition in pendingTransitions {
            for relation in transition.proposal.relations
                where relation.kind == .carriedToAgenda && relation.relatedKind == .agendaItem {
                guard project.nextAgenda.contains(where: {
                    $0.id == relation.relatedObjectID && PendingAIProposalPolicy.isPending($0)
                }) else { continue }
                sourcesByAgendaID[relation.relatedObjectID, default: []].append(
                    .init(
                        kind: .carriedToAgenda,
                        transitionID: transition.proposal.id,
                        evidence: transition.evidence,
                        destructiveApplyState: transition.destructiveApplyState
                    )
                )
            }
        }

        return project.nextAgenda.compactMap { agenda in
            guard var sources = sourcesByAgendaID[agenda.id], !sources.isEmpty else { return nil }
            sources.sort(by: agendaSourceOrder)
            return ManualContinuityBriefAgendaCandidate(agendaItem: agenda, sources: sources)
        }.sorted { agendaOrder($0.agendaItem, $1.agendaItem) }
    }

    private static func agendaApplyState(
        evidence: ManualContinuityBriefEvidenceState
    ) -> ManualContinuityBriefDestructiveApplyState {
        switch evidence {
        case .resolved: return .enabled
        case .dangling: return .disabled(.danglingEvidence)
        case .notRequired: return .disabled(.missingRequiredEvidence)
        }
    }

    // MARK: - Ambiguity candidates

    private static func ambiguousMatch(
        _ group: WorkStateAmbiguousMatchGroup,
        pendingTransitions: [ManualContinuityBriefTransition],
        in project: Project
    ) -> ManualContinuityBriefAmbiguousMatch {
        let incoming = resolve(id: group.incomingObjectID, kind: group.workStateKind, in: project)
        let priorCandidates = group.priorCandidateIDs.compactMap {
            resolve(id: $0, kind: group.workStateKind, in: project)
        }.sorted(by: workStateOrder)
        let selections = group.availableSelections.map { selection in
            ambiguitySelection(
                selection,
                group: group,
                incoming: incoming,
                pendingTransitions: pendingTransitions,
                in: project
            )
        }
        return ManualContinuityBriefAmbiguousMatch(
            group: group,
            incomingState: incoming,
            priorCandidates: priorCandidates,
            selections: selections
        )
    }

    private static func ambiguitySelection(
        _ selection: WorkStateAmbiguousMatchSelection,
        group: WorkStateAmbiguousMatchGroup,
        incoming: ManualContinuityBriefWorkState?,
        pendingTransitions: [ManualContinuityBriefTransition],
        in project: Project
    ) -> ManualContinuityBriefAmbiguitySelection {
        switch selection {
        case .priorCandidate(let priorID):
            let prior = resolve(id: priorID, kind: group.workStateKind, in: project)
            let sibling = pendingTransitions.first {
                $0.proposal.workStateKind == group.workStateKind
                    && $0.proposal.currentObjectID == group.incomingObjectID
                    && $0.proposal.previousStateID == priorID
            }
            let evidence = sibling?.evidence
                ?? incoming?.evidenceReference.map { evidenceState(for: $0, in: project) }
                ?? .notRequired
            return ManualContinuityBriefAmbiguitySelection(
                selection: selection,
                priorState: prior,
                transitionID: sibling?.proposal.id,
                evidence: evidence,
                destructiveApplyState: sibling?.destructiveApplyState
                    ?? .disabled(.missingRequiredEvidence)
            )
        case .new:
            let evidence = incoming?.evidenceReference.map { evidenceState(for: $0, in: project) }
                ?? .notRequired
            return ManualContinuityBriefAmbiguitySelection(
                selection: selection,
                priorState: nil,
                transitionID: nil,
                evidence: evidence,
                destructiveApplyState: agendaApplyState(evidence: evidence)
            )
        }
    }

    // MARK: - Work-state and evidence lookup

    private static func resolve(
        id: UUID,
        kind: WorkStateKind,
        in project: Project
    ) -> ManualContinuityBriefWorkState? {
        switch kind {
        case .decision:
            return project.decisions.first { $0.id == id }.map(ManualContinuityBriefWorkState.decision)
        case .actionItem:
            return project.actionItems.first { $0.id == id }.map(ManualContinuityBriefWorkState.actionItem)
        case .openQuestion:
            return project.openQuestions.first { $0.id == id }.map(ManualContinuityBriefWorkState.openQuestion)
        case .agendaItem:
            return project.nextAgenda.first { $0.id == id }.map(ManualContinuityBriefWorkState.agendaItem)
        }
    }

    private static func resolveAny(id: UUID, in project: Project) -> ManualContinuityBriefWorkState? {
        WorkStateKind.allCases.lazy.compactMap { resolve(id: id, kind: $0, in: project) }.first
    }

    private static func evidenceState(
        for pointer: TransitionEvidencePointer?,
        in project: Project
    ) -> ManualContinuityBriefEvidenceState {
        guard let pointer else { return .notRequired }
        guard let meeting = project.meetings.first(where: { $0.id == pointer.meetingID }) else {
            return .dangling(.missingMeeting)
        }
        guard let segment = meeting.transcriptSegments.first(where: { $0.id == pointer.transcriptSegmentID }) else {
            return .dangling(.missingSegment)
        }
        return .resolved(
            ManualContinuityBriefEvidenceSegment(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                transcriptSegmentID: segment.id,
                text: segment.text
            )
        )
    }

    private static func evidenceState(
        for reference: EvidenceReference?,
        in project: Project
    ) -> ManualContinuityBriefEvidenceState {
        guard let reference else { return .notRequired }
        guard let meeting = project.meetings.first(where: { $0.id == reference.meetingID }) else {
            return .dangling(.missingMeeting)
        }
        guard let segment = meeting.transcriptSegments.first(where: { $0.id == reference.transcriptSegmentID }) else {
            return .dangling(.missingSegment)
        }
        guard segment.text.contains(reference.quote) else {
            return .dangling(.quoteNotInSegment)
        }
        return .resolved(
            ManualContinuityBriefEvidenceSegment(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                transcriptSegmentID: segment.id,
                text: reference.quote
            )
        )
    }

    // MARK: - Deterministic total ordering

    private static func decisionOrder(_ lhs: Decision, _ rhs: Decision) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static func actionItemOrder(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static func openQuestionOrder(_ lhs: OpenQuestion, _ rhs: OpenQuestion) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static func agendaOrder(_ lhs: AgendaItem, _ rhs: AgendaItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static func transitionOrder(
        _ lhs: ManualContinuityBriefTransition,
        _ rhs: ManualContinuityBriefTransition
    ) -> Bool {
        switch (lhs.sourceMeetingOccurredAt, rhs.sourceMeetingOccurredAt) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        switch (lhs.relevantDueDate, rhs.relevantDueDate) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if lhs.proposal.createdAt != rhs.proposal.createdAt {
            return lhs.proposal.createdAt > rhs.proposal.createdAt
        }
        return lhs.proposal.dedupKey < rhs.proposal.dedupKey
    }

    private static func delayOrder(
        _ lhs: ManualContinuityBriefDelayItem,
        _ rhs: ManualContinuityBriefDelayItem
    ) -> Bool {
        let leftPriority = delayPriority(lhs.kind)
        let rightPriority = delayPriority(rhs.kind)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        let left = lhs.actionItem
        let right = rhs.actionItem
        if let left, let right, actionItemOrder(left, right) { return true }
        if let left, let right, actionItemOrder(right, left) { return false }
        if left != nil, right == nil { return true }
        if left == nil, right != nil { return false }
        return transitionOrder(lhs.transition, rhs.transition)
    }

    private static func delayPriority(_ kind: ManualContinuityBriefDelayKind) -> Int {
        switch kind {
        case .blocked: return 0
        case .overdue: return 1
        case .deferred: return 2
        }
    }

    private static func workStateOrder(
        _ lhs: ManualContinuityBriefWorkState,
        _ rhs: ManualContinuityBriefWorkState
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return uuidOrder(lhs.id, rhs.id)
    }

    private static func agendaSourceOrder(
        _ lhs: ManualContinuityBriefAgendaCandidateSource,
        _ rhs: ManualContinuityBriefAgendaCandidateSource
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return optionalUUIDOrder(lhs.transitionID, rhs.transitionID)
    }

    private static func warningOrder(
        _ lhs: ManualContinuityBriefWarning,
        _ rhs: ManualContinuityBriefWarning
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return optionalUUIDOrder(lhs.transitionID, rhs.transitionID)
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private static func optionalUUIDOrder(_ lhs: UUID?, _ rhs: UUID?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return uuidOrder(left, right)
        case (nil, _?): return true
        case (_?, nil): return false
        case (nil, nil): return false
        }
    }
}
