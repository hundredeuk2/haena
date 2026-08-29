import Foundation

/// What a structured progress claim asserts about a task.
///
/// Deliberately three cases and no fourth: each one maps onto a transition the matrix already
/// allows (`completed` -> `.completed`, `deferred`/`blocked` -> `.delayed`). A signal that could not
/// be answered with a transition would be a signal the reviewer can do nothing with.
enum WorkStateProgressSignalKind: String, Codable, Equatable, Sendable, CaseIterable {
    case completed, deferred, blocked
}

/// What a progress signal is about.
///
/// Two shapes, because a meeting reports progress in two different ways. When the task is also
/// extracted from this meeting the signal names that incoming object and the engine matches it to
/// prior state as usual. When the meeting only says "that one is done" about work that already
/// exists, there is no incoming object at all — the signal names the approved prior item directly,
/// and inventing an incoming duplicate to carry it would put a task on the board nobody committed
/// to in this meeting.
enum WorkStateProgressSignalTarget: Equatable, Sendable {
    /// Must exist in `incoming.actionItems`. An id that resolves to nothing is refused rather than
    /// ignored — a dangling signal means the caller and the engine disagree about the input.
    case incomingActionItem(UUID)
    /// Must be an approved prior Action Item of this project, resolved locally from the opaque
    /// reference allow-list. Never a model-supplied UUID.
    case priorActionItem(UUID)
}

/// A structured, evidence-backed progress claim made by the NEW meeting about one task.
///
/// The extraction pipeline produces this only from provider-structured output whose evidence and
/// target reference were validated locally. `completed`/`delayed` therefore rest on a typed signal
/// instead of on a phrase parser.
///
/// The alternative — reading "we finished that" or "let's push it to next week" out of prose — is
/// exactly the class of inference this feature refuses. A missing signal costs the user a manual
/// status change; a wrongly parsed one silently closes work that is still open.
struct WorkStateProgressSignal: Equatable, Sendable {
    let kind: WorkStateProgressSignalKind
    let target: WorkStateProgressSignalTarget
    let evidence: EvidenceReference

    init(
        kind: WorkStateProgressSignalKind,
        target: WorkStateProgressSignalTarget,
        evidence: EvidenceReference
    ) {
        self.kind = kind
        self.target = target
        self.evidence = evidence
    }

    /// The original incoming-object form, kept because it is still the common case.
    init(kind: WorkStateProgressSignalKind, actionItemID: UUID, evidence: EvidenceReference) {
        self.init(kind: kind, target: .incomingActionItem(actionItemID), evidence: evidence)
    }

    var incomingActionItemID: UUID? {
        if case .incomingActionItem(let id) = target { return id }
        return nil
    }

    var priorActionItemID: UUID? {
        if case .priorActionItem(let id) = target { return id }
        return nil
    }
}

/// "This incoming decision revises that approved prior decision." A direct, typed statement from
/// the model, which is why it outranks the engine's own title-similarity matching.
struct DecisionChangeLink: Equatable, Sendable {
    let priorDecisionID: UUID
    let incomingDecisionID: UUID
    let evidence: EvidenceReference
}

/// The kinds of object a question can be answered by. `openQuestion` is absent on purpose: a
/// question answered by another question has not been answered.
enum WorkStateResolutionTargetKind: String, Codable, Equatable, Sendable, CaseIterable {
    case decision, actionItem, agendaItem
}

/// "This prior open question was answered by that new object." Structured, never inferred.
///
/// Resolution is the single most destructive transition in the set — it removes a question from the
/// list the next meeting would otherwise re-raise — so it is the one transition that has no
/// text-similarity path at all. Somebody has to say which object answered it.
struct OpenQuestionResolutionLink: Equatable, Sendable {
    /// Must exist in `prior.openQuestions` and survive admission.
    let priorOpenQuestionID: UUID
    let targetKind: WorkStateResolutionTargetKind
    /// Must exist in the matching `incoming` collection.
    let targetObjectID: UUID
    let evidence: EvidenceReference

    init(
        priorOpenQuestionID: UUID,
        targetKind: WorkStateResolutionTargetKind,
        targetObjectID: UUID,
        evidence: EvidenceReference
    ) {
        self.priorOpenQuestionID = priorOpenQuestionID
        self.targetKind = targetKind
        self.targetObjectID = targetObjectID
        self.evidence = evidence
    }
}

/// "This new action item exists because of that decision."
///
/// Provenance only. It never creates a transition and never changes one — attaching it to the
/// proposals that already exist for the action item is the whole of its effect, because "why does
/// this task exist" is context for a reviewer, not a claim about state changing.
struct DecisionDerivedActionItemLink: Equatable, Sendable {
    /// In `incoming.decisions` or `prior.decisions` — a task can be derived from a decision made in
    /// this meeting or from one taken earlier.
    let decisionID: UUID
    /// Must exist in `incoming.actionItems`.
    let actionItemID: UUID
    let evidence: EvidenceReference

    init(decisionID: UUID, actionItemID: UUID, evidence: EvidenceReference) {
        self.decisionID = decisionID
        self.actionItemID = actionItemID
        self.evidence = evidence
    }
}

/// Everything one transition run is allowed to see.
///
/// Every input is a value. There is no repository, no clock, and no project reference here, which is
/// what makes `WorkStateTransitionEngine.generate` reproducible: the same struct produces the same
/// result on any machine, at any time, which is also what makes the result reviewable in a diff.
struct WorkStateTransitionEngineInput: Equatable, Sendable {
    let projectID: UUID
    let sourceMeetingID: UUID
    /// When the *meeting* happened. This — not wall-clock `now` — is what decides whether an
    /// approved due date was already overdue, so re-running the engine next month cannot turn a
    /// then-current task into a retroactively late one.
    let occurredAt: Date
    let prior: ApprovedWorkStateSnapshot
    let incoming: ValidatedWorkState
    let progressSignals: [WorkStateProgressSignal]
    let resolutionLinks: [OpenQuestionResolutionLink]
    let derivedActionItemLinks: [DecisionDerivedActionItemLink]
    let decisionChangeLinks: [DecisionChangeLink]

    init(
        projectID: UUID,
        sourceMeetingID: UUID,
        occurredAt: Date,
        prior: ApprovedWorkStateSnapshot,
        incoming: ValidatedWorkState,
        progressSignals: [WorkStateProgressSignal] = [],
        resolutionLinks: [OpenQuestionResolutionLink] = [],
        derivedActionItemLinks: [DecisionDerivedActionItemLink] = [],
        decisionChangeLinks: [DecisionChangeLink] = []
    ) {
        self.projectID = projectID
        self.sourceMeetingID = sourceMeetingID
        self.occurredAt = occurredAt
        self.prior = prior
        self.incoming = incoming
        self.progressSignals = progressSignals
        self.resolutionLinks = resolutionLinks
        self.derivedActionItemLinks = derivedActionItemLinks
        self.decisionChangeLinks = decisionChangeLinks
    }
}

/// A transition the engine declined to state, and the finite reason why.
///
/// Kept as data for the same reason `RejectedProposal` is: a caller must be able to report "three of
/// the six items could not be linked, here is the category of each" without re-running anything.
/// A refusal is never an error — it is the engine choosing to say nothing rather than guess.
struct WorkStateTransitionRefusal: Equatable, Sendable, Codable {
    let workStateKind: WorkStateKind
    /// Nil when the refusal happened before any particular transition was in view — admission, or a
    /// structured link that never resolved.
    let attemptedTransition: WorkStateTransitionKind?
    let previousStateID: UUID?
    let currentObjectID: UUID?
    let reason: WorkStateTransitionReason

    init(
        workStateKind: WorkStateKind,
        attemptedTransition: WorkStateTransitionKind?,
        previousStateID: UUID?,
        currentObjectID: UUID?,
        reason: WorkStateTransitionReason
    ) {
        self.workStateKind = workStateKind
        self.attemptedTransition = attemptedTransition
        self.previousStateID = previousStateID
        self.currentObjectID = currentObjectID
        self.reason = reason
    }
}

/// The choice a reviewer can make when text matching found more than one plausible prior item.
///
/// `new` is a review choice rather than an engine proposal. Keeping it in this finite contract lets
/// the reviewer say "none of these" without the engine manufacturing a `.new` row beside unresolved
/// candidates.
enum WorkStateAmbiguousMatchSelection: Equatable, Sendable {
    case priorCandidate(UUID)
    case new
}

/// One deterministic review boundary around all candidates for one incoming object.
struct WorkStateAmbiguousMatchGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let sourceMeetingID: UUID
    let workStateKind: WorkStateKind
    let incomingObjectID: UUID
    /// Sorted by lowercased UUID string and de-duplicated before identity is computed.
    let priorCandidateIDs: [UUID]
    let dedupKey: String

    init(
        projectID: UUID,
        sourceMeetingID: UUID,
        workStateKind: WorkStateKind,
        incomingObjectID: UUID,
        priorCandidateIDs: [UUID]
    ) {
        let sortedCandidateIDs = Array(Set(priorCandidateIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let key = Self.dedupKey(
            projectID: projectID,
            sourceMeetingID: sourceMeetingID,
            workStateKind: workStateKind,
            incomingObjectID: incomingObjectID,
            priorCandidateIDs: sortedCandidateIDs
        )
        self.id = WorkStateTransitionProposal.deterministicID(forDedupKey: key)
        self.projectID = projectID
        self.sourceMeetingID = sourceMeetingID
        self.workStateKind = workStateKind
        self.incomingObjectID = incomingObjectID
        self.priorCandidateIDs = sortedCandidateIDs
        self.dedupKey = key
    }

    var availableSelections: [WorkStateAmbiguousMatchSelection] {
        priorCandidateIDs.map(WorkStateAmbiguousMatchSelection.priorCandidate) + [.new]
    }

    func accepts(_ selection: WorkStateAmbiguousMatchSelection) -> Bool {
        switch selection {
        case .priorCandidate(let id): return priorCandidateIDs.contains(id)
        case .new: return true
        }
    }

    private static func dedupKey(
        projectID: UUID,
        sourceMeetingID: UUID,
        workStateKind: WorkStateKind,
        incomingObjectID: UUID,
        priorCandidateIDs: [UUID]
    ) -> String {
        [
            "haena.work-state-ambiguity.v1",
            projectID.uuidString.lowercased(),
            sourceMeetingID.uuidString.lowercased(),
            workStateKind.rawValue,
            incomingObjectID.uuidString.lowercased(),
            priorCandidateIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
        ].joined(separator: "|")
    }
}

/// Stable identity of one continuity run. It contains identifiers only and is safe to persist.
struct WorkStateContinuityRunIdentity: Codable, Equatable, Sendable {
    let runID: UUID
    let projectID: UUID
    let sourceMeetingID: UUID

    init(projectID: UUID, sourceMeetingID: UUID) {
        let key = [
            "haena.work-state-continuity-run.v1",
            projectID.uuidString.lowercased(),
            sourceMeetingID.uuidString.lowercased()
        ].joined(separator: "|")
        self.runID = WorkStateTransitionProposal.deterministicID(forDedupKey: key)
        self.projectID = projectID
        self.sourceMeetingID = sourceMeetingID
    }
}

/// Persisted, privacy-safe explanation of a statement the engine declined to make.
///
/// There is deliberately no string payload: no transcript, title, participant name, or free-form
/// explanation can enter this record. `reason` and the attempted transition are finite enums.
struct WorkStateTransitionRefusalRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let projectID: UUID
    let sourceMeetingID: UUID
    let workStateKind: WorkStateKind
    let attemptedTransition: WorkStateTransitionKind?
    let previousStateID: UUID?
    let currentObjectID: UUID?
    let reason: WorkStateTransitionReason
    let dedupKey: String
    let createdAt: Date

    init(
        run: WorkStateContinuityRunIdentity,
        refusal: WorkStateTransitionRefusal,
        createdAt: Date
    ) {
        let key = [
            "haena.work-state-refusal.v1",
            run.runID.uuidString.lowercased(),
            refusal.workStateKind.rawValue,
            refusal.attemptedTransition?.rawValue ?? "none",
            refusal.previousStateID?.uuidString.lowercased() ?? "none",
            refusal.currentObjectID?.uuidString.lowercased() ?? "none",
            refusal.reason.rawValue
        ].joined(separator: "|")
        self.id = WorkStateTransitionProposal.deterministicID(forDedupKey: key)
        self.runID = run.runID
        self.projectID = run.projectID
        self.sourceMeetingID = run.sourceMeetingID
        self.workStateKind = refusal.workStateKind
        self.attemptedTransition = refusal.attemptedTransition
        self.previousStateID = refusal.previousStateID
        self.currentObjectID = refusal.currentObjectID
        self.reason = refusal.reason
        self.dedupKey = key
        self.createdAt = createdAt
    }

    init(copying record: WorkStateTransitionRefusalRecord, createdAt: Date) {
        self.id = record.id
        self.runID = record.runID
        self.projectID = record.projectID
        self.sourceMeetingID = record.sourceMeetingID
        self.workStateKind = record.workStateKind
        self.attemptedTransition = record.attemptedTransition
        self.previousStateID = record.previousStateID
        self.currentObjectID = record.currentObjectID
        self.reason = record.reason
        self.dedupKey = record.dedupKey
        self.createdAt = createdAt
    }
}

/// Both halves of one run. The refusals matter as much as the proposals: a run that produced two
/// proposals and silently dropped four objects is not the same outcome as one that produced two.
struct WorkStateTransitionEngineResult: Equatable, Sendable {
    /// Sorted by `dedupKey` ascending.
    let proposals: [WorkStateTransitionProposal]
    /// Sorted by deterministic group key. Each group exposes candidate and `new` choices.
    let ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup]
    /// Sorted deterministically. The service converts these finite values into refusal records tied
    /// to run/project/meeting identity before persistence.
    let refusals: [WorkStateTransitionRefusal]

    init(
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup] = [],
        refusals: [WorkStateTransitionRefusal]
    ) {
        self.proposals = proposals
        self.ambiguousMatchGroups = ambiguousMatchGroups
        self.refusals = refusals
    }
}
