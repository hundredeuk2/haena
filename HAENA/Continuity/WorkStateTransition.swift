import CryptoKit
import Foundation

/// Which of the four work states a transition talks about.
///
/// Raw values are part of the on-disk contract, so an unknown future value must fail decoding
/// rather than degrade to a neighbouring case — the same reasoning as `AssigneeAttributionBasis`.
/// A transition record that silently changed which work state it referred to would relocate a
/// user's review decision onto a different object.
enum WorkStateKind: String, Codable, Equatable, Sendable, CaseIterable {
    case decision
    case actionItem = "action_item"
    case openQuestion = "open_question"
    case agendaItem = "agenda_item"
}

/// What the transition claims happened between the prior approved state and the new meeting.
///
/// Only `new` and `same` can ever be automatic; every other case asserts a change to state a user
/// already approved, and therefore has to be confirmed. See `WorkStateTransitionMatrix` for which
/// of these are even expressible per work state.
enum WorkStateTransitionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case new, same, changed, completed, delayed, resolved
}

/// The structural fact that justified the link. Exactly one per proposal.
///
/// This is deliberately a closed set of *structural* facts, not a confidence score: the reviewer's
/// question is always "what in the data made you say this?", and a number cannot answer it. A basis
/// that cannot be pointed at in stored state or in a typed signal does not exist here, which is why
/// there is no "model thought so" case.
enum WorkStateTransitionBasis: String, Codable, Equatable, Sendable, CaseIterable {
    case noPriorCandidate            = "no_prior_candidate"
    case exactNormalizedTextMatch    = "exact_normalized_text_match"
    case nearTextMatch               = "near_text_match"
    case overdueApprovedDueDate      = "overdue_approved_due_date"
    case structuredProgressSignal    = "structured_progress_signal"
    case structuredResolutionLink    = "structured_resolution_link"
    /// The model named the approved decision this one revises. Distinct from `nearTextMatch`
    /// because the two answer to different evidence: one is a statement we asked for, the other is
    /// the engine's own similarity guess, and a reviewer deciding whether to trust a `changed`
    /// proposal needs to know which of the two produced it.
    case structuredDecisionChangeLink = "structured_decision_change_link"
}

/// Finite, privacy-safe explanation. Never free text, never transcript, never a person's name.
///
/// The finiteness is the privacy guarantee: a `String` explanation would eventually carry a quote
/// or a participant's name into a store that is not the transcript store, and no reviewer of a
/// later change would notice. Anything a reason cannot express is not shown rather than smuggled
/// through as prose.
enum WorkStateTransitionReason: String, Codable, Equatable, Sendable, CaseIterable {
    case ambiguousPriorCandidates      = "ambiguous_prior_candidates"
    case similarityOnly                = "similarity_only"
    case missingEvidence               = "missing_evidence"
    case evidenceNotInSourceMeeting    = "evidence_not_in_source_meeting"
    case crossProjectCandidate         = "cross_project_candidate"
    case unresolvedAssigneeAttribution = "unresolved_assignee_attribution"
    case unsupportedTransitionForKind  = "unsupported_transition_for_kind"
    case priorItemNotApproved          = "prior_item_not_approved"
    case stateChangeRequiresApproval   = "state_change_requires_approval"
    case unknownReferencedObject       = "unknown_referenced_object"
}
// A `missingDueDate`/`dueDateNotOverdue` pair was specified and then removed before it ever shipped.
// Both would only have been reachable if an explicit deferral signal were gated on the prior item's
// dates — and it is not, deliberately: a task with no due date can still be deferred, and a stated
// deferral is its own structural basis. Since decoding rejects unknown raw values by design, an
// unreachable case is not harmless forward-compatibility; it is a claim that the engine can give a
// reason it can never give.

/// The engine only generates `.pendingReview`. Approval is a follow-up task, but its finite states
/// already exist so the repository can keep user-owned review state separate from engine upserts.
enum WorkStateTransitionReviewStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case pendingReview = "pending_review"
    case approved
    case rejected
}

/// Structured detail for a `.delayed` proposal. An overdue proposal deliberately carries nil:
/// lateness is already represented by `.overdueApprovedDueDate`, while this value preserves what
/// the meeting explicitly said without adding free text to the transition store.
enum WorkStateTransitionProgressDisposition: String, Codable, Equatable, Sendable, CaseIterable {
    case deferred
    case blocked
}

/// How a transition relates to some *other* object, when the relationship is not the transition
/// itself. Kept separate from `transitionKind` so "this question is now on the agenda" does not
/// have to be spelled as a fake agenda-item transition.
enum WorkStateRelationKind: String, Codable, Equatable, Sendable, CaseIterable {
    case resolvedBy      = "resolved_by"
    case derivedFrom     = "derived_from"
    case carriedToAgenda = "carried_to_agenda"
}

struct WorkStateTransitionRelation: Codable, Equatable, Sendable {
    let kind: WorkStateRelationKind
    let relatedKind: WorkStateKind
    let relatedObjectID: UUID

    init(kind: WorkStateRelationKind, relatedKind: WorkStateKind, relatedObjectID: UUID) {
        self.kind = kind
        self.relatedKind = relatedKind
        self.relatedObjectID = relatedObjectID
    }
}

/// Deliberately NOT `EvidenceReference`: the quote is omitted so a transition record never
/// duplicates transcript text. The quote is recovered from the referenced object's own evidence.
///
/// One consequence is intentional: this store can be inspected, exported, or deleted without
/// reasoning about what transcript content it happens to contain, because it structurally contains
/// none.
struct TransitionEvidencePointer: Codable, Equatable, Sendable {
    let meetingID: UUID
    let transcriptSegmentID: UUID

    init(meetingID: UUID, transcriptSegmentID: UUID) {
        self.meetingID = meetingID
        self.transcriptSegmentID = transcriptSegmentID
    }
}

/// One statement of the form "relative to approved state, this work state did X in this meeting."
///
/// A proposal is a *value*, never a mutation: nothing in v0 writes to `Project`. The engine returns
/// these, the repository stores them in its own file, and a user's approved work state is only ever
/// changed by a user.
struct WorkStateTransitionProposal: Identifiable, Codable, Equatable, Sendable {
    /// Deterministic; derived from `dedupKey` via `deterministicID(forDedupKey:)`. It is not random
    /// so that re-running the engine over an unchanged meeting produces the same row identity
    /// rather than a second row that merely looks alike.
    let id: UUID
    let projectID: UUID
    let workStateKind: WorkStateKind
    let transitionKind: WorkStateTransitionKind
    let previousStateID: UUID?
    let currentObjectID: UUID?
    let sourceMeetingID: UUID
    let evidence: TransitionEvidencePointer?
    let basis: WorkStateTransitionBasis
    let progressDisposition: WorkStateTransitionProgressDisposition?
    /// Sorted by `rawValue` and de-duplicated by the producer, so two runs that reached the same
    /// conclusion by different code paths still compare equal.
    let reasons: [WorkStateTransitionReason]
    let requiresConfirmation: Bool
    let reviewStatus: WorkStateTransitionReviewStatus
    let relations: [WorkStateTransitionRelation]
    let dedupKey: String
    let createdAt: Date

    /// Spelled out rather than left to synthesis so the defaults exist: the common shape of a
    /// proposal has no relations and no reasons, and a v0 producer has no reason to ever pass a
    /// `reviewStatus` other than `.pendingReview`.
    ///
    /// This intentionally does not sort or de-duplicate `reasons`/`relations`. Normalization is the
    /// producer's job (it is part of the engine's determinism contract); doing it here as well
    /// would hide a producer bug behind a value type that quietly repaired it.
    init(
        id: UUID,
        projectID: UUID,
        workStateKind: WorkStateKind,
        transitionKind: WorkStateTransitionKind,
        previousStateID: UUID?,
        currentObjectID: UUID?,
        sourceMeetingID: UUID,
        evidence: TransitionEvidencePointer? = nil,
        basis: WorkStateTransitionBasis,
        progressDisposition: WorkStateTransitionProgressDisposition? = nil,
        reasons: [WorkStateTransitionReason] = [],
        requiresConfirmation: Bool,
        reviewStatus: WorkStateTransitionReviewStatus = .pendingReview,
        relations: [WorkStateTransitionRelation] = [],
        dedupKey: String,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.workStateKind = workStateKind
        self.transitionKind = transitionKind
        self.previousStateID = previousStateID
        self.currentObjectID = currentObjectID
        self.sourceMeetingID = sourceMeetingID
        self.evidence = evidence
        self.basis = basis
        self.progressDisposition = progressDisposition
        self.reasons = reasons
        self.requiresConfirmation = requiresConfirmation
        self.reviewStatus = reviewStatus
        self.relations = relations
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        precondition(
            hasValidProgressDispositionContract,
            "progress disposition is only valid for a structured delayed action item"
        )
    }

    var hasValidProgressDispositionContract: Bool {
        guard progressDisposition != nil else { return true }
        return workStateKind == .actionItem
            && transitionKind == .delayed
            && basis == .structuredProgressSignal
    }
}

// MARK: - Idempotency

extension WorkStateTransitionProposal {
    /// The identity of a transition, as a string a human can read in a diff.
    ///
    /// `basis`, `reasons`, `relations`, and `createdAt` are deliberately absent: re-running over
    /// the same structural facts must land on the same stored row even when the *explanation* is
    /// enriched by a later version of the engine. If explanation were part of the key, every
    /// improvement to reason reporting would fork every existing row.
    ///
    /// `transitionKind` IS part of the key, because one prior/current pair can legitimately carry
    /// both a `changed` and a `delayed` statement, and those must not overwrite each other.
    static func dedupKey(
        projectID: UUID,
        workStateKind: WorkStateKind,
        transitionKind: WorkStateTransitionKind,
        previousStateID: UUID?,
        currentObjectID: UUID?
    ) -> String {
        [
            "haena.work-state-transition.v1",
            renderUUID(projectID),
            workStateKind.rawValue,
            transitionKind.rawValue,
            renderOptionalUUID(previousStateID),
            renderOptionalUUID(currentObjectID)
        ].joined(separator: "|")
    }

    /// RFC 4122 v5-shaped UUID derived by SHA-256 over the dedup key. Same key -> same UUID, in
    /// this process, in a later process, and on another machine.
    ///
    /// Hashing rather than storing the key as the id keeps `Identifiable` conformance on a `UUID`
    /// like every other model here, while still making the id a pure function of the structural
    /// facts. It is v5-*shaped* rather than a true namespaced v5 because the namespace is already
    /// carried by the `haena.work-state-transition.v1` prefix inside the key itself.
    static func deterministicID(forDedupKey key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        // Version 5 (name-based, SHA-1 in the RFC; the shape is what consumers read) and the
        // RFC 4122 variant, so this value is a well-formed UUID rather than 16 arbitrary bytes.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Lowercased so the key never depends on `uuidString`'s uppercase rendering — a formatting
    /// change on either side of the comparison would otherwise silently duplicate every row.
    private static func renderUUID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// A nil id renders as the literal `none`, not as an empty field: an empty field would make
    /// `(nil, x)` and `(x, nil)` collide for any pair where the separator lands in the same place.
    private static func renderOptionalUUID(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return renderUUID(id)
    }
}

// MARK: - Transition matrix

/// Which transitions each work state is even allowed to express.
///
/// This is a hard gate rather than a hint: a transition the matrix rejects is refused outright, so
/// the set of statements the feature can make about a work state is bounded by a table a reviewer
/// can read in one screen.
enum WorkStateTransitionMatrix {
    static func supportedTransitions(for kind: WorkStateKind) -> Set<WorkStateTransitionKind> {
        switch kind {
        case .decision:
            // A decision is not a task and not a question: it cannot complete, be late, or be
            // answered. It can only be recorded, repeated, or revised.
            return [.new, .same, .changed]
        case .actionItem:
            // The only work state with a lifecycle and a due date, hence the only one that can
            // meaningfully be `completed` or `delayed`.
            return [.new, .same, .changed, .completed, .delayed]
        case .openQuestion:
            // `resolved` is the whole point of a question; `completed`/`delayed` belong to tasks.
            return [.new, .same, .changed, .resolved]
        case .agendaItem:
            // Deliberately the most conservative row. `AgendaItem` is the only work state allowed
            // to be user-authored (`evidence` and `confidence` are both optional precisely so a
            // hand-added entry never has to fabricate a source), and its `title`/`reason` are
            // free-form, so it has the weakest identity of the four. v0 will only say "this agenda
            // line is new" or "this agenda line is the same one as before". An open question that
            // stays on the agenda is modelled as an `openQuestion` transition carrying a
            // `.carriedToAgenda` relation — not as an `agendaItem` transition.
            return [.new, .same]
        }
    }

    static func supports(_ transition: WorkStateTransitionKind, for kind: WorkStateKind) -> Bool {
        supportedTransitions(for: kind).contains(transition)
    }
}

// MARK: - Approval policy

/// The mirror image of `PendingAIProposalPolicy`: which stored records count as user-approved prior
/// state that a transition is allowed to reference.
///
/// The two policies have to stay complementary. `PendingAIProposalPolicy` answers "is this still
/// waiting on a person?"; this one answers "did a person already accept this?". A transition that
/// referenced a still-pending record would be reasoning about one model proposal from another
/// model proposal, which is exactly the compounding-error loop this feature exists to avoid.
///
/// One asymmetry with `PendingAIProposalPolicy` is deliberate and worth stating, because it looks
/// like an oversight: that policy requires `evidence != nil` in every case, and this one requires no
/// evidence at all. The two are asking different questions. Evidence is what makes a *model's* claim
/// admissible, which is why the engine refuses any incoming object without it. Approval is what
/// makes a *person's* state authoritative, and a decision a user typed in themselves is fully
/// authoritative while having no transcript behind it. Requiring evidence here would silently
/// exclude every hand-entered decision, task, and question from continuity — the user's own work
/// would be the only work the product could not track across meetings.
///
/// The visible consequence: a transition may name a `previousStateID` whose object has no evidence,
/// so a reviewer following the evidence pointer sees only the new side of the pair. That is correct
/// — there is no transcript to point at on the old side — but a Manual Brief must not present it as
/// missing data.
enum ApprovedWorkStatePolicy {
    static func isApproved(_ decision: Decision) -> Bool {
        decision.status == .confirmed
    }

    /// `.completed`/`.cancelled` are intentionally NOT approved prior state: a finished task is not
    /// something the next meeting transitions away from, and treating it as a candidate would
    /// resurrect closed work every time a similar title came up again.
    static func isApproved(_ actionItem: ActionItem) -> Bool {
        actionItem.status == .confirmed || actionItem.status == .inProgress
    }

    /// `OpenQuestionStatus` has no `.proposed` case, so `.open` alone cannot tell an approved
    /// question from a freshly extracted one — `reviewedAt` is what separates them, exactly as in
    /// `PendingAIProposalPolicy`.
    static func isApproved(_ question: OpenQuestion) -> Bool {
        question.status == .open && question.reviewedAt != nil
    }

    /// Same reasoning as `OpenQuestion`: `.pending` is shared by a user-approved agenda line and an
    /// unreviewed suggestion.
    static func isApproved(_ agendaItem: AgendaItem) -> Bool {
        agendaItem.status == .pending && agendaItem.reviewedAt != nil
    }
}

/// The approved prior state a transition run is allowed to look at.
///
/// Taking a snapshot rather than reading `Project` directly is what makes the engine a pure
/// function: the engine cannot reach a repository, cannot observe a later edit mid-run, and cannot
/// write anything back.
struct ApprovedWorkStateSnapshot: Equatable, Sendable {
    let projectID: UUID
    let decisions: [Decision]
    let actionItems: [ActionItem]
    let openQuestions: [OpenQuestion]
    let agendaItems: [AgendaItem]

    /// Filters `project` through `ApprovedWorkStatePolicy`. Objects whose `projectID` does not match
    /// the project's own id are dropped here as well — a malformed store must not be able to smuggle
    /// another project's item into a snapshot.
    init(project: Project) {
        self.projectID = project.id
        self.decisions = project.decisions.filter {
            $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
        }
        self.actionItems = project.actionItems.filter {
            $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
        }
        self.openQuestions = project.openQuestions.filter {
            $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
        }
        self.agendaItems = project.nextAgenda.filter {
            $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
        }
    }

    /// Memberwise, for tests and for callers assembling a snapshot by hand.
    ///
    /// This one does not filter: a caller building a snapshot explicitly is stating what the prior
    /// state is, and the engine re-checks project membership and approval during admission anyway.
    init(
        projectID: UUID,
        decisions: [Decision],
        actionItems: [ActionItem],
        openQuestions: [OpenQuestion],
        agendaItems: [AgendaItem]
    ) {
        self.projectID = projectID
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.agendaItems = agendaItems
    }
}
