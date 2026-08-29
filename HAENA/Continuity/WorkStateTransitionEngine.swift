import Foundation

/// Decides what changed between a project's approved work state and one new meeting's mapped
/// output, and says so only where the data supports it.
///
/// Four rules drive everything here, and each one exists because the failure it prevents is worse
/// than the work it leaves undone:
///
/// 1. **Purity.** `generate` is a total function of its arguments. No repository, no `Date()`, no
///    `UUID()`, no I/O, no randomness. `now` is stamped into `createdAt` and is used for nothing
///    else — lateness is judged against `input.occurredAt`, the meeting's own time, so re-running
///    the engine later cannot retroactively make a task overdue.
/// 2. **Identity is derived, never minted.** Every proposal id comes from
///    `WorkStateTransitionProposal.deterministicID(forDedupKey:)`. Re-running over an unchanged
///    meeting reproduces the same rows rather than a parallel set that merely looks alike — which
///    is what makes the store upsertable and the output diffable.
/// 3. **Similarity never auto-confirms.** Exact normalized equality against exactly one candidate
///    is the only path to `requiresConfirmation == false` for a link, and only for `.same`. A near
///    match is always a question put to the user, never an answer.
/// 4. **Ambiguity is never resolved by picking.** Two plausible prior items produce one
///    deterministic review group and one confirm-required proposal per candidate. The group's
///    explicit `.new` choice lets the user reject every candidate without the engine manufacturing
///    a new item before that choice is made.
///
/// There is no natural-language date parsing anywhere in this file, and no inference of lateness,
/// completion, or resolution from prose. Those three transitions rest exclusively on typed inputs
/// (`WorkStateProgressSignal`, `OpenQuestionResolutionLink`) or on stored dates.
enum WorkStateTransitionEngine {

    /// Jaccard overlap at or above this counts as a near match. Named once, here, because it is the
    /// single tunable number in the whole engine and a reviewer should not have to grep for it.
    ///
    /// The value only ever gates whether the user is *asked* about a pair. Raising it drops
    /// questions; lowering it adds them. Neither direction can cause an automatic link, so this
    /// number cannot on its own corrupt approved state.
    static let nearMatchSimilarityThreshold = 0.6

    static func generate(
        _ input: WorkStateTransitionEngineInput,
        now: Date
    ) -> WorkStateTransitionEngineResult {
        var builder = Builder(projectID: input.projectID, sourceMeetingID: input.sourceMeetingID)

        // MARK: Admission (3.1)

        let incomingDecisions = admitIncoming(
            input.incoming.decisions, kind: .decision,
            id: \Decision.id, projectID: \Decision.projectID,
            evidence: \Decision.evidence, text: \Decision.statement,
            input: input, into: &builder
        )
        let incomingActionItems = admitIncoming(
            input.incoming.actionItems, kind: .actionItem,
            id: \ActionItem.id, projectID: \ActionItem.projectID,
            evidence: \ActionItem.evidence, text: \ActionItem.title,
            input: input, into: &builder
        )
        let incomingOpenQuestions = admitIncoming(
            input.incoming.openQuestions, kind: .openQuestion,
            id: \OpenQuestion.id, projectID: \OpenQuestion.projectID,
            evidence: \OpenQuestion.evidence, text: \OpenQuestion.question,
            input: input, into: &builder
        )
        let incomingAgendaItems = admitIncoming(
            input.incoming.agendaItems, kind: .agendaItem,
            id: \AgendaItem.id, projectID: \AgendaItem.projectID,
            evidence: \AgendaItem.evidence, text: \AgendaItem.title,
            input: input, into: &builder
        )

        // Cross-project exclusion runs before the approval check, so an item belonging to another
        // project is never even asked whether it is approved. A same-looking decision from a
        // neighbouring project must be structurally incapable of becoming a candidate here.
        let priorDecisions = admitPrior(
            input.prior.decisions, kind: .decision,
            id: \Decision.id, projectID: \Decision.projectID, text: \Decision.statement,
            expectedProjectID: input.projectID,
            isApproved: { (item: Decision) in ApprovedWorkStatePolicy.isApproved(item) },
            into: &builder
        )
        let priorActionItems = admitPrior(
            input.prior.actionItems, kind: .actionItem,
            id: \ActionItem.id, projectID: \ActionItem.projectID, text: \ActionItem.title,
            expectedProjectID: input.projectID,
            isApproved: { (item: ActionItem) in ApprovedWorkStatePolicy.isApproved(item) },
            into: &builder
        )
        let priorOpenQuestions = admitPrior(
            input.prior.openQuestions, kind: .openQuestion,
            id: \OpenQuestion.id, projectID: \OpenQuestion.projectID, text: \OpenQuestion.question,
            expectedProjectID: input.projectID,
            isApproved: { (item: OpenQuestion) in ApprovedWorkStatePolicy.isApproved(item) },
            into: &builder
        )
        let priorAgendaItems = admitPrior(
            input.prior.agendaItems, kind: .agendaItem,
            id: \AgendaItem.id, projectID: \AgendaItem.projectID, text: \AgendaItem.title,
            expectedProjectID: input.projectID,
            isApproved: { (item: AgendaItem) in ApprovedWorkStatePolicy.isApproved(item) },
            into: &builder
        )

        // MARK: Text matching (3.2, 3.3)

        // MARK: Direct decision-change references

        // A named prior outranks the text matcher. The model was asked which approved decision this
        // one revises; re-deriving that from titles could contradict the answer, and a pair of
        // similar prior decisions would raise an ambiguity group over a question already settled.
        let admittedPriorDecisionIDs = Set(priorDecisions.map { $0.id })
        let admittedIncomingDecisionIDs = Set(incomingDecisions.map { $0.id })
        var directDecisionChanges: [UUID: DecisionChangeLink] = [:]

        for link in input.decisionChangeLinks {
            guard admittedIncomingDecisionIDs.contains(link.incomingDecisionID),
                  admittedPriorDecisionIDs.contains(link.priorDecisionID) else {
                builder.refuse(
                    kind: .decision, attempted: .changed, previousStateID: link.priorDecisionID,
                    currentObjectID: link.incomingDecisionID, reason: .unknownReferencedObject
                )
                continue
            }
            guard link.evidence.meetingID == input.sourceMeetingID else {
                builder.refuse(
                    kind: .decision, attempted: .changed, previousStateID: link.priorDecisionID,
                    currentObjectID: link.incomingDecisionID, reason: .evidenceNotInSourceMeeting
                )
                continue
            }
            // Two priors claiming the same incoming decision is the ambiguity this contract exists
            // to avoid, so neither is stated: the first is withdrawn along with the second.
            if let existing = directDecisionChanges.removeValue(forKey: link.incomingDecisionID) {
                builder.refuse(
                    kind: .decision, attempted: .changed, previousStateID: existing.priorDecisionID,
                    currentObjectID: existing.incomingDecisionID, reason: .ambiguousPriorCandidates
                )
                builder.refuse(
                    kind: .decision, attempted: .changed, previousStateID: link.priorDecisionID,
                    currentObjectID: link.incomingDecisionID, reason: .ambiguousPriorCandidates
                )
                continue
            }
            directDecisionChanges[link.incomingDecisionID] = link
        }

        for incoming in incomingDecisions {
            if let link = directDecisionChanges[incoming.id] {
                builder.emit(
                    kind: .decision, transition: .changed,
                    previousStateID: link.priorDecisionID, currentObjectID: incoming.id,
                    evidence: TransitionEvidencePointer(
                        meetingID: link.evidence.meetingID,
                        transcriptSegmentID: link.evidence.transcriptSegmentID
                    ),
                    basis: .structuredDecisionChangeLink,
                    reasons: [.stateChangeRequiresApproval], requiresConfirmation: true
                )
                continue
            }
            _ = resolveMatch(
                kind: .decision, incoming: incoming, priors: priorDecisions,
                sameDowngradeReasons: [], into: &builder
            )
        }

        // Which single prior action item each incoming action item resolved to, when it resolved to
        // exactly one. Progress signals may only speak about a pair the text matcher already
        // settled — a signal cannot itself decide which prior task it is about. Read by key only;
        // never iterated, so it cannot leak dictionary order into the output.
        var priorForIncomingActionItem: [UUID: UUID] = [:]
        for incoming in incomingActionItems {
            // Attribution is never a matching signal. It enters here only to take away an automatic
            // `.same`: an owner the mapper could not resolve is a question for the user, but it can
            // neither create a link nor break one.
            let downgrade: [WorkStateTransitionReason]
            if let attribution = incoming.object.proposedAssigneeAttribution,
               attribution.resolution != .resolved {
                downgrade = [.unresolvedAssigneeAttribution]
            } else {
                downgrade = []
            }

            if let priorID = resolveMatch(
                kind: .actionItem, incoming: incoming, priors: priorActionItems,
                sameDowngradeReasons: downgrade, into: &builder
            ) {
                priorForIncomingActionItem[incoming.id] = priorID
            }
        }

        for incoming in incomingOpenQuestions {
            _ = resolveMatch(
                kind: .openQuestion, incoming: incoming, priors: priorOpenQuestions,
                sameDowngradeReasons: [], into: &builder
            )
        }

        for incoming in incomingAgendaItems {
            _ = resolveMatch(
                kind: .agendaItem, incoming: incoming, priors: priorAgendaItems,
                sameDowngradeReasons: [], into: &builder
            )
        }

        // MARK: Structured progress signals (3.4, 3.5b)

        let admittedActionItemIDs = Set(incomingActionItems.map { $0.id })
        // Prior items already spoken for by an explicit deferral. The overdue pass below skips
        // them so the two bases collapse to one `delayed` statement per prior item. Membership
        // tests only; never iterated.
        var priorIDsWithSignalledDelay: Set<UUID> = []

        let admittedPriorActionItemIDs = Set(priorActionItems.map { $0.id })

        for signal in input.progressSignals {
            let attempted: WorkStateTransitionKind = signal.kind == .completed ? .completed : .delayed
            // The prior-target form carries its own subject, so it skips incoming admission and
            // matching entirely; there is no incoming object, and `currentObjectID` stays nil all
            // the way through to the proposal.
            let incomingID = signal.incomingActionItemID
            let priorID: UUID

            switch signal.target {
            case .incomingActionItem(let id):
                guard admittedActionItemIDs.contains(id) else {
                    builder.refuse(
                        kind: .actionItem, attempted: attempted, previousStateID: nil,
                        currentObjectID: id, reason: .unknownReferencedObject
                    )
                    continue
                }
                guard signal.evidence.meetingID == input.sourceMeetingID else {
                    builder.refuse(
                        kind: .actionItem, attempted: attempted, previousStateID: nil,
                        currentObjectID: id, reason: .evidenceNotInSourceMeeting
                    )
                    continue
                }
                // A signal about an item that matched nothing, or matched two things, has no prior
                // state to transition away from. Refusing is the only honest outcome: picking one of
                // two candidates here would let a status claim silently select its own subject.
                guard let matched = priorForIncomingActionItem[id] else {
                    builder.refuse(
                        kind: .actionItem, attempted: attempted, previousStateID: nil,
                        currentObjectID: id, reason: .ambiguousPriorCandidates
                    )
                    continue
                }
                priorID = matched
            case .priorActionItem(let id):
                guard admittedPriorActionItemIDs.contains(id) else {
                    builder.refuse(
                        kind: .actionItem, attempted: attempted, previousStateID: id,
                        currentObjectID: nil, reason: .unknownReferencedObject
                    )
                    continue
                }
                guard signal.evidence.meetingID == input.sourceMeetingID else {
                    builder.refuse(
                        kind: .actionItem, attempted: attempted, previousStateID: id,
                        currentObjectID: nil, reason: .evidenceNotInSourceMeeting
                    )
                    continue
                }
                priorID = id
            }

            let pointer = TransitionEvidencePointer(
                meetingID: signal.evidence.meetingID,
                transcriptSegmentID: signal.evidence.transcriptSegmentID
            )

            switch signal.kind {
            case .completed:
                // Emitted *in addition to* the `.same`/`.changed` proposal for this pair. They carry
                // different transition kinds and therefore different dedup keys; "this is the same
                // task" and "this task is now done" are both true and separately reviewable.
                builder.emit(
                    kind: .actionItem, transition: .completed,
                    previousStateID: priorID, currentObjectID: incomingID,
                    evidence: pointer, basis: .structuredProgressSignal,
                    reasons: [.stateChangeRequiresApproval], requiresConfirmation: true
                )
            case .deferred, .blocked:
                let disposition: WorkStateTransitionProgressDisposition =
                    signal.kind == .deferred ? .deferred : .blocked
                builder.emit(
                    kind: .actionItem, transition: .delayed,
                    previousStateID: priorID, currentObjectID: incomingID,
                    evidence: pointer, basis: .structuredProgressSignal,
                    progressDisposition: disposition,
                    reasons: [.stateChangeRequiresApproval], requiresConfirmation: true
                )
                priorIDsWithSignalledDelay.insert(priorID)
            }
        }

        // MARK: Overdue approved due dates (3.5a)

        // Lateness here is a fact about stored state, not about anything said in the new meeting, so
        // this pass needs no incoming object at all — hence `currentObjectID` and `evidence` are nil.
        // A prior item with no due date produces nothing and no refusal: "we never set a date" is
        // the common case, and reporting it every run would bury the refusals that mean something.
        for prior in priorActionItems where !priorIDsWithSignalledDelay.contains(prior.id) {
            guard let dueDate = prior.object.dueDate, dueDate < input.occurredAt else { continue }
            builder.emit(
                kind: .actionItem, transition: .delayed,
                previousStateID: prior.id, currentObjectID: nil,
                evidence: nil, basis: .overdueApprovedDueDate,
                reasons: [.stateChangeRequiresApproval], requiresConfirmation: true
            )
        }

        // MARK: Open question resolution (3.6)

        let priorOpenQuestionIDs = Set(priorOpenQuestions.map { $0.id })
        let admittedDecisionIDs = Set(incomingDecisions.map { $0.id })
        let admittedAgendaItemIDs = Set(incomingAgendaItems.map { $0.id })

        for link in input.resolutionLinks {
            let targetKind = workStateKind(for: link.targetKind)

            guard priorOpenQuestionIDs.contains(link.priorOpenQuestionID) else {
                builder.refuse(
                    kind: .openQuestion, attempted: .resolved,
                    previousStateID: link.priorOpenQuestionID,
                    currentObjectID: link.targetObjectID, reason: .unknownReferencedObject
                )
                continue
            }

            let targetExists: Bool
            switch link.targetKind {
            case .decision: targetExists = admittedDecisionIDs.contains(link.targetObjectID)
            case .actionItem: targetExists = admittedActionItemIDs.contains(link.targetObjectID)
            case .agendaItem: targetExists = admittedAgendaItemIDs.contains(link.targetObjectID)
            }
            guard targetExists else {
                builder.refuse(
                    kind: .openQuestion, attempted: .resolved,
                    previousStateID: link.priorOpenQuestionID,
                    currentObjectID: link.targetObjectID, reason: .unknownReferencedObject
                )
                continue
            }

            guard link.evidence.meetingID == input.sourceMeetingID else {
                builder.refuse(
                    kind: .openQuestion, attempted: .resolved,
                    previousStateID: link.priorOpenQuestionID,
                    currentObjectID: link.targetObjectID, reason: .evidenceNotInSourceMeeting
                )
                continue
            }

            // A question that moved onto the agenda has still left the open-question list, so the
            // transition is `.resolved` either way; only the relation distinguishes "answered" from
            // "carried forward". Spelling the agenda case as an `agendaItem` transition instead
            // would claim an identity for an agenda line that `AgendaItem` cannot support.
            let relationKind: WorkStateRelationKind =
                link.targetKind == .agendaItem ? .carriedToAgenda : .resolvedBy

            builder.emit(
                kind: .openQuestion, transition: .resolved,
                previousStateID: link.priorOpenQuestionID, currentObjectID: link.targetObjectID,
                evidence: TransitionEvidencePointer(
                    meetingID: link.evidence.meetingID,
                    transcriptSegmentID: link.evidence.transcriptSegmentID
                ),
                basis: .structuredResolutionLink,
                reasons: [.stateChangeRequiresApproval], requiresConfirmation: true,
                relations: [
                    WorkStateTransitionRelation(
                        kind: relationKind,
                        relatedKind: targetKind,
                        relatedObjectID: link.targetObjectID
                    )
                ]
            )
        }

        // MARK: Decision-derived action items (3.7)

        let priorDecisionIDs = Set(priorDecisions.map { $0.id })

        for link in input.derivedActionItemLinks {
            guard admittedActionItemIDs.contains(link.actionItemID) else {
                builder.refuse(
                    kind: .actionItem, attempted: nil, previousStateID: nil,
                    currentObjectID: link.actionItemID, reason: .unknownReferencedObject
                )
                continue
            }
            // A task may be derived from a decision taken in this meeting or from one taken earlier,
            // so both sides of the input are searched.
            guard admittedDecisionIDs.contains(link.decisionID)
                    || priorDecisionIDs.contains(link.decisionID) else {
                builder.refuse(
                    kind: .decision, attempted: nil, previousStateID: nil,
                    currentObjectID: link.decisionID, reason: .unknownReferencedObject
                )
                continue
            }
            guard link.evidence.meetingID == input.sourceMeetingID else {
                builder.refuse(
                    kind: .actionItem, attempted: nil, previousStateID: nil,
                    currentObjectID: link.actionItemID, reason: .evidenceNotInSourceMeeting
                )
                continue
            }

            // Provenance, not a transition: this attaches to whatever was already said about the
            // task and creates nothing. "Why does this task exist" is context for the reviewer; it
            // is not itself a claim that any state changed.
            builder.attachRelation(
                WorkStateTransitionRelation(
                    kind: .derivedFrom, relatedKind: .decision, relatedObjectID: link.decisionID
                ),
                toProposalsFor: .actionItem,
                currentObjectID: link.actionItemID
            )
        }

        return builder.finish(now: now)
    }

    // MARK: - Admission

    /// One admitted object plus the two derived values every later stage needs, so neither the
    /// normalization nor the evidence pointer is recomputed (and possibly recomputed differently)
    /// further down.
    private struct Admitted<Object> {
        let object: Object
        let id: UUID
        let normalizedText: String
        let evidence: TransitionEvidencePointer
    }

    /// A prior object that survived admission. It carries no evidence pointer: a transition always
    /// cites the *new* meeting, never the meeting the prior item came from.
    private struct PriorCandidate<Object> {
        let object: Object
        let id: UUID
        let normalizedText: String
    }

    /// Admission for the new meeting's objects, in the fixed order project -> evidence present ->
    /// evidence belongs to this meeting. First failure excludes the object and emits one refusal;
    /// the object is never partially admitted.
    private static func admitIncoming<Object>(
        _ objects: [Object],
        kind: WorkStateKind,
        id: KeyPath<Object, UUID>,
        projectID: KeyPath<Object, UUID>,
        evidence: KeyPath<Object, EvidenceReference?>,
        text: KeyPath<Object, String>,
        input: WorkStateTransitionEngineInput,
        into builder: inout Builder
    ) -> [Admitted<Object>] {
        var admitted: [Admitted<Object>] = []

        for object in objects {
            let objectID = object[keyPath: id]

            guard object[keyPath: projectID] == input.projectID else {
                builder.refuse(
                    kind: kind, attempted: nil, previousStateID: nil,
                    currentObjectID: objectID, reason: .crossProjectCandidate
                )
                continue
            }
            guard let reference = object[keyPath: evidence] else {
                builder.refuse(
                    kind: kind, attempted: nil, previousStateID: nil,
                    currentObjectID: objectID, reason: .missingEvidence
                )
                continue
            }
            // An object whose evidence cites a different meeting cannot be described as something
            // *this* meeting said, whatever else is true about it.
            guard reference.meetingID == input.sourceMeetingID else {
                builder.refuse(
                    kind: kind, attempted: nil, previousStateID: nil,
                    currentObjectID: objectID, reason: .evidenceNotInSourceMeeting
                )
                continue
            }

            admitted.append(
                Admitted(
                    object: object,
                    id: objectID,
                    normalizedText: normalize(object[keyPath: text]),
                    evidence: TransitionEvidencePointer(
                        meetingID: reference.meetingID,
                        transcriptSegmentID: reference.transcriptSegmentID
                    )
                )
            )
        }

        return admitted
    }

    /// Admission for stored prior state. Evidence is deliberately not required: an approved item may
    /// have been typed by a person, and a hand-entered decision is no less binding than an extracted
    /// one. Approval — not provenance — is what qualifies it as prior state.
    private static func admitPrior<Object>(
        _ objects: [Object],
        kind: WorkStateKind,
        id: KeyPath<Object, UUID>,
        projectID: KeyPath<Object, UUID>,
        text: KeyPath<Object, String>,
        expectedProjectID: UUID,
        isApproved: (Object) -> Bool,
        into builder: inout Builder
    ) -> [PriorCandidate<Object>] {
        var candidates: [PriorCandidate<Object>] = []

        for object in objects {
            let objectID = object[keyPath: id]

            guard object[keyPath: projectID] == expectedProjectID else {
                builder.refuse(
                    kind: kind, attempted: nil, previousStateID: objectID,
                    currentObjectID: nil, reason: .crossProjectCandidate
                )
                continue
            }
            // Referencing a still-pending proposal would mean reasoning about one model output from
            // another, which compounds error instead of grounding it.
            guard isApproved(object) else {
                builder.refuse(
                    kind: kind, attempted: nil, previousStateID: objectID,
                    currentObjectID: nil, reason: .priorItemNotApproved
                )
                continue
            }

            candidates.append(
                PriorCandidate(
                    object: object,
                    id: objectID,
                    normalizedText: normalize(object[keyPath: text])
                )
            )
        }

        return candidates
    }

    // MARK: - Matching

    /// Emits the `new`/`same`/`changed` statement for one admitted object.
    ///
    /// Returns the single prior id when — and only when — the object resolved unambiguously to one
    /// prior item *and* that statement was actually emitted. Everything downstream that needs "which
    /// prior task is this" reads that return value, so a progress signal can never attach itself to
    /// a pair the matcher refused to commit to.
    private static func resolveMatch<Incoming, Prior>(
        kind: WorkStateKind,
        incoming: Admitted<Incoming>,
        priors: [PriorCandidate<Prior>],
        sameDowngradeReasons: [WorkStateTransitionReason],
        into builder: inout Builder
    ) -> UUID? {
        let exact = priors.filter { $0.normalizedText == incoming.normalizedText }
        let near = priors.filter { candidate in
            guard candidate.normalizedText != incoming.normalizedText else { return false }
            let similarity = jaccardSimilarity(candidate.normalizedText, incoming.normalizedText)
            // No upper bound. Two different strings can score exactly 1.0, because Jaccard compares
            // token *sets*: "fix the bug" and "fix the the bug" share the set {fix, the, bug}.
            // Excluding 1.0 here would drop that pair out of candidacy altogether and emit `.new`
            // beside the item it duplicates — the precise outcome this engine exists to prevent.
            // Exact equality is already excluded by the guard above, so this bound is unnecessary
            // as well as harmful.
            return similarity >= nearMatchSimilarityThreshold
        }

        if exact.isEmpty && near.isEmpty {
            builder.emit(
                kind: kind, transition: .new,
                previousStateID: nil, currentObjectID: incoming.id,
                evidence: incoming.evidence, basis: .noPriorCandidate,
                reasons: [], requiresConfirmation: false
            )
            return nil
        }

        if exact.count == 1 && near.isEmpty {
            // The one automatic link in the whole engine. It asserts that nothing changed, so
            // accepting it alters no approved state — which is exactly why it is allowed to be
            // automatic, and why an unresolved assignee is enough to take that away.
            let emitted = builder.emit(
                kind: kind, transition: .same,
                previousStateID: exact[0].id, currentObjectID: incoming.id,
                evidence: incoming.evidence, basis: .exactNormalizedTextMatch,
                reasons: sameDowngradeReasons,
                requiresConfirmation: !sameDowngradeReasons.isEmpty
            )
            return emitted ? exact[0].id : nil
        }

        if exact.isEmpty && near.count == 1 {
            let emitted = builder.emit(
                kind: kind, transition: .changed,
                previousStateID: near[0].id, currentObjectID: incoming.id,
                evidence: incoming.evidence, basis: .nearTextMatch,
                reasons: [.similarityOnly], requiresConfirmation: true
            )
            return emitted ? near[0].id : nil
        }

        // Ambiguous: one exact plus at least one near, two or more exact, or two or more near.
        // Every candidate gets its own confirm-required row and no `.new` is emitted. `.changed` is
        // used uniformly — including for the exact candidate — so the user is never shown a
        // pre-picked winner among candidates the engine could not separate.
        builder.registerAmbiguity(
            kind: kind,
            incomingObjectID: incoming.id,
            priorCandidateIDs: (exact + near).map(\.id)
        )
        for candidate in exact {
            builder.emit(
                kind: kind, transition: .changed,
                previousStateID: candidate.id, currentObjectID: incoming.id,
                evidence: incoming.evidence, basis: .exactNormalizedTextMatch,
                reasons: [.ambiguousPriorCandidates], requiresConfirmation: true
            )
        }
        for candidate in near {
            builder.emit(
                kind: kind, transition: .changed,
                previousStateID: candidate.id, currentObjectID: incoming.id,
                evidence: incoming.evidence, basis: .nearTextMatch,
                reasons: [.ambiguousPriorCandidates, .similarityOnly], requiresConfirmation: true
            )
        }
        // For a kind that cannot express `.changed` every row above became an
        // `.unsupportedTransitionForKind` refusal, which says why each candidate was dropped but not
        // that the object was ambiguous at all. One more refusal keeps that fact from being lost.
        if !WorkStateTransitionMatrix.supports(.changed, for: kind) {
            builder.refuse(
                kind: kind, attempted: .changed, previousStateID: nil,
                currentObjectID: incoming.id, reason: .ambiguousPriorCandidates
            )
        }
        return nil
    }

    // MARK: - Text normalization

    /// Characters stripped from the end of a normalized string. Terminal punctuation is the one
    /// difference between two renderings of the same sentence that carries no meaning for identity.
    private static let trailingSentenceTerminators: Set<Character> = [".", "!", "?", "。", "…"]

    /// The only matching signal in v0: Unicode NFC, trimmed, lowercased, internal whitespace runs
    /// collapsed to one space, trailing sentence terminators removed.
    ///
    /// Everything it does is a rendering difference. It does not stem, translate, expand
    /// abbreviations, or drop stop words — each of those would let two genuinely different
    /// statements normalize to the same string and become an automatic `.same`.
    static func normalize(_ value: String) -> String {
        let collapsed = value
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")

        // Whitespace is stripped alongside the terminators, not only before them. Collapsing runs
        // first means "결정했습니다 ." arrives here as "결정했습니다 .", and removing just the "."
        // would leave a trailing space that no longer equals "결정했습니다" — turning an exact match
        // into a near one purely because someone typed a space before the full stop.
        var result = collapsed[...]
        while let last = result.last, trailingSentenceTerminators.contains(last) || last.isWhitespace {
            result = result.dropLast()
        }
        return String(result)
    }

    /// Jaccard overlap of the whitespace-split token sets.
    ///
    /// Set overlap rather than edit distance on purpose: it is symmetric, insensitive to word order,
    /// and cheap to explain to a reviewer who asks why two lines were offered as the same item.
    static func jaccardSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        let unionCount = lhsTokens.union(rhsTokens).count
        guard unionCount > 0 else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(unionCount)
    }

    private static func workStateKind(for target: WorkStateResolutionTargetKind) -> WorkStateKind {
        switch target {
        case .decision: return .decision
        case .actionItem: return .actionItem
        case .agendaItem: return .agendaItem
        }
    }

    // MARK: - Output assembly

    /// A proposal still under construction. It exists only because relations are attached after the
    /// fact (3.7) and `WorkStateTransitionProposal` is immutable by design — the mutable stage is
    /// kept private so no caller can ever observe a half-built proposal.
    private struct Draft {
        let workStateKind: WorkStateKind
        let transitionKind: WorkStateTransitionKind
        let previousStateID: UUID?
        let currentObjectID: UUID?
        let evidence: TransitionEvidencePointer?
        let basis: WorkStateTransitionBasis
        let progressDisposition: WorkStateTransitionProgressDisposition?
        let reasons: [WorkStateTransitionReason]
        let requiresConfirmation: Bool
        var relations: [WorkStateTransitionRelation]
        let dedupKey: String
    }

    /// Collects drafts and refusals, enforcing the transition matrix and dedup-key uniqueness on the
    /// way in so no caller in `generate` has to remember to.
    ///
    /// Everything it appends to is an `Array`, appended to in a fixed traversal order. No output is
    /// ever built by iterating a `Set` or `Dictionary`; the sets in this file are membership tests
    /// only. That is what makes two runs over the same input byte-identical.
    private struct Builder {
        let projectID: UUID
        let sourceMeetingID: UUID

        private var drafts: [Draft] = []
        private var refusals: [WorkStateTransitionRefusal] = []
        private var ambiguityGroups: [WorkStateAmbiguousMatchGroup] = []
        private var claimedDedupKeys: Set<String> = []
        private var claimedAmbiguityKeys: Set<String> = []

        init(projectID: UUID, sourceMeetingID: UUID) {
            self.projectID = projectID
            self.sourceMeetingID = sourceMeetingID
        }

        mutating func refuse(
            kind: WorkStateKind,
            attempted: WorkStateTransitionKind?,
            previousStateID: UUID?,
            currentObjectID: UUID?,
            reason: WorkStateTransitionReason
        ) {
            refusals.append(
                WorkStateTransitionRefusal(
                    workStateKind: kind,
                    attemptedTransition: attempted,
                    previousStateID: previousStateID,
                    currentObjectID: currentObjectID,
                    reason: reason
                )
            )
        }

        mutating func registerAmbiguity(
            kind: WorkStateKind,
            incomingObjectID: UUID,
            priorCandidateIDs: [UUID]
        ) {
            let group = WorkStateAmbiguousMatchGroup(
                projectID: projectID,
                sourceMeetingID: sourceMeetingID,
                workStateKind: kind,
                incomingObjectID: incomingObjectID,
                priorCandidateIDs: priorCandidateIDs
            )
            guard claimedAmbiguityKeys.insert(group.dedupKey).inserted else { return }
            ambiguityGroups.append(group)
        }

        /// Returns whether a proposal for this dedup key now exists. A pair the matrix forbids
        /// becomes a refusal and returns `false`; a duplicate key is dropped and returns `true`,
        /// because the statement was already made (a `.deferred` and a `.blocked` signal about the
        /// same task are one `delayed` claim, not two).
        @discardableResult
        mutating func emit(
            kind: WorkStateKind,
            transition: WorkStateTransitionKind,
            previousStateID: UUID?,
            currentObjectID: UUID?,
            evidence: TransitionEvidencePointer?,
            basis: WorkStateTransitionBasis,
            progressDisposition: WorkStateTransitionProgressDisposition? = nil,
            reasons: [WorkStateTransitionReason],
            requiresConfirmation: Bool,
            relations: [WorkStateTransitionRelation] = []
        ) -> Bool {
            // A disallowed (kind, transition) pair is refused, never bent into the nearest allowed
            // transition. Approximating here would let the matrix be reviewed as a table while the
            // engine quietly worked around it.
            guard WorkStateTransitionMatrix.supports(transition, for: kind) else {
                refuse(
                    kind: kind, attempted: transition, previousStateID: previousStateID,
                    currentObjectID: currentObjectID, reason: .unsupportedTransitionForKind
                )
                return false
            }

            let key = WorkStateTransitionProposal.dedupKey(
                projectID: projectID,
                workStateKind: kind,
                transitionKind: transition,
                previousStateID: previousStateID,
                currentObjectID: currentObjectID
            )
            guard claimedDedupKeys.insert(key).inserted else { return true }

            drafts.append(
                Draft(
                    workStateKind: kind,
                    transitionKind: transition,
                    previousStateID: previousStateID,
                    currentObjectID: currentObjectID,
                    evidence: evidence,
                    basis: basis,
                    progressDisposition: progressDisposition,
                    reasons: reasons,
                    requiresConfirmation: requiresConfirmation,
                    relations: relations,
                    dedupKey: key
                )
            )
            return true
        }

        /// Attaches a relation to every proposal already emitted about one object. Proposals with no
        /// current object — an overdue-only `delayed`, which describes stored state rather than
        /// anything in this meeting — are untouched by construction.
        mutating func attachRelation(
            _ relation: WorkStateTransitionRelation,
            toProposalsFor kind: WorkStateKind,
            currentObjectID: UUID
        ) {
            for index in drafts.indices
            where drafts[index].workStateKind == kind
                && drafts[index].currentObjectID == currentObjectID {
                drafts[index].relations.append(relation)
            }
        }

        func finish(now: Date) -> WorkStateTransitionEngineResult {
            let proposals = drafts.map { draft in
                WorkStateTransitionProposal(
                    id: WorkStateTransitionProposal.deterministicID(forDedupKey: draft.dedupKey),
                    projectID: projectID,
                    workStateKind: draft.workStateKind,
                    transitionKind: draft.transitionKind,
                    previousStateID: draft.previousStateID,
                    currentObjectID: draft.currentObjectID,
                    sourceMeetingID: sourceMeetingID,
                    evidence: draft.evidence,
                    basis: draft.basis,
                    progressDisposition: draft.progressDisposition,
                    reasons: sortedUniqueReasons(draft.reasons),
                    requiresConfirmation: draft.requiresConfirmation,
                    reviewStatus: .pendingReview,
                    relations: sortedUniqueRelations(draft.relations),
                    dedupKey: draft.dedupKey,
                    createdAt: now
                )
            }
            .sorted { $0.dedupKey < $1.dedupKey }

            // `attemptedTransition` is a tiebreaker beyond the contract's four sort fields: two
            // refusals can agree on all four and still differ, and an unspecified order between them
            // would make an otherwise reproducible run non-reproducible.
            let sortedRefusals = refusals.sorted { lhs, rhs in
                (
                    lhs.workStateKind.rawValue,
                    lhs.reason.rawValue,
                    lhs.previousStateID?.uuidString ?? "",
                    lhs.currentObjectID?.uuidString ?? "",
                    lhs.attemptedTransition?.rawValue ?? ""
                ) < (
                    rhs.workStateKind.rawValue,
                    rhs.reason.rawValue,
                    rhs.previousStateID?.uuidString ?? "",
                    rhs.currentObjectID?.uuidString ?? "",
                    rhs.attemptedTransition?.rawValue ?? ""
                )
            }

            return WorkStateTransitionEngineResult(
                proposals: proposals,
                ambiguousMatchGroups: ambiguityGroups.sorted { $0.dedupKey < $1.dedupKey },
                refusals: sortedRefusals
            )
        }

        /// De-duplicated by filtering with a seen-set rather than by round-tripping through a `Set`,
        /// so no output ever depends on set iteration order even transiently.
        private func sortedUniqueReasons(
            _ reasons: [WorkStateTransitionReason]
        ) -> [WorkStateTransitionReason] {
            var seen: Set<String> = []
            return reasons
                .filter { seen.insert($0.rawValue).inserted }
                .sorted { $0.rawValue < $1.rawValue }
        }

        private func sortedUniqueRelations(
            _ relations: [WorkStateTransitionRelation]
        ) -> [WorkStateTransitionRelation] {
            var seen: Set<String> = []
            return relations
                .filter {
                    seen.insert(
                        "\($0.kind.rawValue)|\($0.relatedKind.rawValue)|\($0.relatedObjectID.uuidString)"
                    ).inserted
                }
                .sorted { lhs, rhs in
                    (lhs.kind.rawValue, lhs.relatedKind.rawValue, lhs.relatedObjectID.uuidString)
                        < (rhs.kind.rawValue, rhs.relatedKind.rawValue, rhs.relatedObjectID.uuidString)
                }
        }
    }
}
