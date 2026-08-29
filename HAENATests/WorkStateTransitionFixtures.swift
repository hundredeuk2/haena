import XCTest
@testable import HAENA

/// Synthetic prior/incoming work state for the Meeting Continuity v0 scenario matrix.
///
/// Three constraints shaped this file:
///
/// 1. **Nothing here is real.** No corpus, no holdout, no gold file. Every string is written for
///    this suite, so a scenario can never accidentally assert on a recorded meeting.
/// 2. **Text pairs are chosen, not tuned.** The scenario tests need "the same sentence" and "a
///    recognisably revised sentence", so the revised variants differ by exactly one token out of
///    a handful. That is far enough from the near-match boundary that the tests keep meaning if
///    the threshold is ever re-tuned — these fixtures assert on the *contract*, not on a number.
///    The unrelated strings share no token at all, so an unintended candidate cannot appear.
/// 3. **Prior and incoming live in different meetings.** Admission requires an incoming object's
///    evidence to belong to the source meeting, so a fixture that reused one meeting for both
///    halves would pass for the wrong reason.
enum WorkStateTransitionFixtures {

    // MARK: - Identity

    /// Deterministic ids in their own namespace, so they can never collide with `TestFixtures`
    /// or `MeetingResultFixtures`.
    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: "0000000C-0000-0000-0000-\(String(format: "%012d", index))")!
    }

    static let projectID = MeetingResultFixtures.projectA
    /// A second project used only to prove that a look-alike item in it is never linked.
    static let otherProjectID = MeetingResultFixtures.projectB

    /// The meeting the approved prior state came from.
    static let priorMeetingID = MeetingResultFixtures.meetingA
    /// The meeting being processed now. Every admitted incoming object cites this one.
    static let sourceMeetingID = MeetingResultFixtures.meetingB

    static let priorSegmentID = MeetingResultFixtures.segmentA
    static let sourceSegmentID = MeetingResultFixtures.segmentB
    /// Deliberately different from `sourceSegmentID`: a `completed`/`delayed` proposal must carry
    /// the *signal's* evidence, and identical segment ids would hide a mix-up.
    static let signalSegmentID = uuid(1)
    /// Same reasoning for resolution and derived-from links.
    static let linkSegmentID = uuid(2)

    // MARK: - Time

    static let priorCreatedAt = TestFixtures.fixedDate
    /// When the new meeting happened. Overdue is measured against this, never against `now`.
    static let occurredAt = Date(timeIntervalSince1970: 1_700_100_000)
    /// When `generate` was called. Distinct from `occurredAt` so a test can tell which one a
    /// timestamp came from. Whole seconds, so a JSON round-trip is exact under any date strategy.
    static let generatedAt = Date(timeIntervalSince1970: 1_700_100_500)
    static let overdueDueDate = Date(timeIntervalSince1970: 1_699_900_000)
    static let futureDueDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Text

    static let decisionStatement = "ship the billing migration in february with the vendor api"
    /// One token changed out of ten: unmistakably the same decision, revised.
    static let revisedDecisionStatement = "ship the billing migration in march with the vendor api"
    /// Shares no token with either statement above.
    static let unrelatedDecisionStatement = "adopt a weekly retro cadence"

    static let actionItemTitle = "draft the metrics definition document"
    static let revisedActionItemTitle = "draft the metrics definition summary"
    /// Shares no token with `actionItemTitle`.
    static let unrelatedActionItemTitle = "renew vendor contract paperwork"
    /// A third task title, disjoint from both of the above.
    static let anotherActionItemTitle = "publish release notes"

    static let openQuestionText = "who owns the pricing page rewrite"
    static let revisedOpenQuestionText = "who owns the pricing page redesign"
    static let unrelatedOpenQuestionText = "can we fund a second designer"

    static let agendaTitle = "confirm the launch checklist owners"
    static let revisedAgendaTitle = "confirm the launch checklist reviewers"
    static let unrelatedAgendaTitle = "review hiring plan"
    static let agendaReason = "left unresolved in the previous meeting"

    static let priorQuote = "quoted from the previous meeting"
    static let sourceQuote = "quoted from the meeting being processed"
    static let signalQuote = "quoted progress statement"
    static let linkQuote = "quoted resolution statement"

    // MARK: - Evidence

    static func priorEvidence(quote: String = priorQuote) -> EvidenceReference {
        EvidenceReference(meetingID: priorMeetingID, transcriptSegmentID: priorSegmentID, quote: quote)
    }

    static func sourceEvidence(
        segment: UUID = sourceSegmentID,
        quote: String = sourceQuote
    ) -> EvidenceReference {
        EvidenceReference(meetingID: sourceMeetingID, transcriptSegmentID: segment, quote: quote)
    }

    static func signalEvidence(quote: String = signalQuote) -> EvidenceReference {
        sourceEvidence(segment: signalSegmentID, quote: quote)
    }

    static func linkEvidence(quote: String = linkQuote) -> EvidenceReference {
        sourceEvidence(segment: linkSegmentID, quote: quote)
    }

    /// Evidence pointing at the *previous* meeting. Used to prove a mismatched citation is
    /// refused rather than quietly accepted.
    static func foreignEvidence() -> EvidenceReference {
        EvidenceReference(meetingID: priorMeetingID, transcriptSegmentID: priorSegmentID, quote: priorQuote)
    }

    // MARK: - Approved prior state
    //
    // Each builder produces the status `ApprovedWorkStatePolicy` treats as user-approved, so a
    // scenario never has to restate the policy to get a usable prior item.

    static func approvedDecision(
        id: UUID,
        statement: String = decisionStatement,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.priorEvidence()
    ) -> Decision {
        MeetingResultFixtures.decision(
            id: id,
            inProject: projectID,
            fromMeeting: priorMeetingID,
            statement: statement,
            status: .confirmed,
            evidence: evidence,
            createdAt: priorCreatedAt,
            updatedAt: priorCreatedAt
        )
    }

    static func approvedActionItem(
        id: UUID,
        title: String = actionItemTitle,
        dueDate: Date? = nil,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.priorEvidence()
    ) -> ActionItem {
        MeetingResultFixtures.actionItem(
            id: id,
            inProject: projectID,
            fromMeeting: priorMeetingID,
            title: title,
            assigneeID: nil,
            dueDate: dueDate,
            status: .confirmed,
            evidence: evidence,
            createdAt: priorCreatedAt,
            updatedAt: priorCreatedAt
        )
    }

    /// `.open` alone does not mean approved — `reviewedAt` is what separates an accepted question
    /// from one an extractor just proposed.
    static func approvedOpenQuestion(
        id: UUID,
        question: String = openQuestionText,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.priorEvidence()
    ) -> OpenQuestion {
        MeetingResultFixtures.openQuestion(
            id: id,
            inProject: projectID,
            fromMeeting: priorMeetingID,
            question: question,
            status: .open,
            evidence: evidence,
            createdAt: priorCreatedAt,
            reviewedAt: priorCreatedAt
        )
    }

    /// Built by hand rather than through `MeetingResultFixtures` because `reason` is free text
    /// that the privacy test needs to control.
    static func approvedAgendaItem(
        id: UUID,
        title: String = agendaTitle,
        reason: String = agendaReason,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.priorEvidence()
    ) -> AgendaItem {
        AgendaItem(
            id: id,
            projectID: projectID,
            title: title,
            reason: reason,
            sourceMeetingID: priorMeetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: priorCreatedAt,
            evidence: evidence,
            confidence: evidence == nil ? nil : Confidence(0.5),
            reviewedAt: priorCreatedAt
        )
    }

    // MARK: - Incoming (this meeting's mapped output)

    static func incomingDecision(
        id: UUID,
        statement: String = decisionStatement,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.sourceEvidence()
    ) -> Decision {
        MeetingResultFixtures.decision(
            id: id,
            inProject: projectID,
            fromMeeting: sourceMeetingID,
            statement: statement,
            status: .proposed,
            evidence: evidence,
            createdAt: occurredAt,
            updatedAt: occurredAt
        )
    }

    static func incomingActionItem(
        id: UUID,
        title: String = actionItemTitle,
        attribution: AssigneeAttribution? = nil,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.sourceEvidence()
    ) -> ActionItem {
        var item = MeetingResultFixtures.actionItem(
            id: id,
            inProject: projectID,
            fromMeeting: sourceMeetingID,
            title: title,
            assigneeID: nil,
            dueDate: nil,
            status: .proposed,
            evidence: evidence,
            createdAt: occurredAt,
            updatedAt: occurredAt
        )
        // Set after construction: `MeetingResultFixtures` predates attribution, and attribution is
        // provenance rather than a defining property of the task.
        item.proposedAssigneeAttribution = attribution
        return item
    }

    static func incomingOpenQuestion(
        id: UUID,
        question: String = openQuestionText,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.sourceEvidence()
    ) -> OpenQuestion {
        MeetingResultFixtures.openQuestion(
            id: id,
            inProject: projectID,
            fromMeeting: sourceMeetingID,
            question: question,
            status: .open,
            evidence: evidence,
            createdAt: occurredAt,
            reviewedAt: nil
        )
    }

    static func incomingAgendaItem(
        id: UUID,
        title: String = agendaTitle,
        reason: String = agendaReason,
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        evidence: EvidenceReference? = WorkStateTransitionFixtures.sourceEvidence()
    ) -> AgendaItem {
        AgendaItem(
            id: id,
            projectID: projectID,
            title: title,
            reason: reason,
            sourceMeetingID: sourceMeetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: occurredAt,
            evidence: evidence,
            confidence: evidence == nil ? nil : Confidence(0.5),
            reviewedAt: nil
        )
    }

    /// An attribution whose resolution is anything but `.resolved`. The basis is irrelevant to the
    /// contract — only the resolution is allowed to influence confirmation.
    static func unresolvedAttribution(
        _ resolution: AssigneeAttributionResolution = .ambiguousParticipantMatch
    ) -> AssigneeAttribution {
        AssigneeAttribution(
            basis: .explicitName,
            reference: "attribution-reference",
            speakerLabel: "SPEAKER_01",
            resolution: resolution
        )
    }

    static func resolvedAttribution() -> AssigneeAttribution {
        AssigneeAttribution(
            basis: .explicitName,
            reference: "attribution-reference",
            speakerLabel: "SPEAKER_01",
            resolution: .resolved
        )
    }

    // MARK: - Assembly

    static func snapshot(
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        agendaItems: [AgendaItem] = []
    ) -> ApprovedWorkStateSnapshot {
        ApprovedWorkStateSnapshot(
            projectID: projectID,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            agendaItems: agendaItems
        )
    }

    static func incoming(
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        agendaItems: [AgendaItem] = []
    ) -> ValidatedWorkState {
        ValidatedWorkState(
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            agendaItems: agendaItems,
            rejected: []
        )
    }

    static func input(
        inProject projectID: UUID = WorkStateTransitionFixtures.projectID,
        sourceMeetingID: UUID = WorkStateTransitionFixtures.sourceMeetingID,
        occurredAt: Date = WorkStateTransitionFixtures.occurredAt,
        prior: ApprovedWorkStateSnapshot? = nil,
        incoming: ValidatedWorkState = WorkStateTransitionFixtures.incoming(),
        progressSignals: [WorkStateProgressSignal] = [],
        resolutionLinks: [OpenQuestionResolutionLink] = [],
        derivedActionItemLinks: [DecisionDerivedActionItemLink] = [],
        decisionChangeLinks: [DecisionChangeLink] = []
    ) -> WorkStateTransitionEngineInput {
        WorkStateTransitionEngineInput(
            projectID: projectID,
            sourceMeetingID: sourceMeetingID,
            occurredAt: occurredAt,
            prior: prior ?? snapshot(inProject: projectID),
            incoming: incoming,
            progressSignals: progressSignals,
            resolutionLinks: resolutionLinks,
            derivedActionItemLinks: derivedActionItemLinks,
            decisionChangeLinks: decisionChangeLinks
        )
    }

    // MARK: - A representative populated input

    /// Ids of the objects in `representativeInput`, so a test can name what it is asserting about
    /// instead of digging them back out of the input.
    enum Representative {
        static let newDecision = WorkStateTransitionFixtures.uuid(900)
        static let priorMatchedActionItem = WorkStateTransitionFixtures.uuid(901)
        static let incomingMatchedActionItem = WorkStateTransitionFixtures.uuid(902)
        static let priorOverdueActionItem = WorkStateTransitionFixtures.uuid(903)
        static let priorRevisedQuestion = WorkStateTransitionFixtures.uuid(904)
        static let incomingRevisedQuestion = WorkStateTransitionFixtures.uuid(905)
        static let priorResolvedQuestion = WorkStateTransitionFixtures.uuid(906)
        static let newAgendaItem = WorkStateTransitionFixtures.uuid(907)
    }

    /// One input that exercises every transition kind at once: `new` (a decision and an agenda
    /// line with no prior counterpart), `same` + `completed` (an exactly-matched action item with
    /// a completion signal), `delayed` (an overdue prior action item nobody mentioned), `changed`
    /// (a revised open question), and `resolved` (a prior question answered by the new decision).
    ///
    /// It exists so the Manual Continuity Brief contract can be asserted against a result that
    /// actually contains one of everything, rather than against six separate thin results.
    static func representativeInput() -> WorkStateTransitionEngineInput {
        input(
            prior: snapshot(
                actionItems: [
                    approvedActionItem(id: Representative.priorMatchedActionItem, title: actionItemTitle),
                    approvedActionItem(
                        id: Representative.priorOverdueActionItem,
                        title: unrelatedActionItemTitle,
                        dueDate: overdueDueDate
                    )
                ],
                openQuestions: [
                    approvedOpenQuestion(id: Representative.priorRevisedQuestion, question: openQuestionText),
                    approvedOpenQuestion(
                        id: Representative.priorResolvedQuestion,
                        question: unrelatedOpenQuestionText
                    )
                ]
            ),
            incoming: incoming(
                decisions: [
                    incomingDecision(id: Representative.newDecision, statement: unrelatedDecisionStatement)
                ],
                actionItems: [
                    incomingActionItem(id: Representative.incomingMatchedActionItem, title: actionItemTitle)
                ],
                openQuestions: [
                    incomingOpenQuestion(
                        id: Representative.incomingRevisedQuestion,
                        question: revisedOpenQuestionText
                    )
                ],
                agendaItems: [
                    incomingAgendaItem(id: Representative.newAgendaItem, title: agendaTitle)
                ]
            ),
            progressSignals: [
                WorkStateProgressSignal(
                    kind: .completed,
                    actionItemID: Representative.incomingMatchedActionItem,
                    evidence: signalEvidence()
                )
            ],
            resolutionLinks: [
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: Representative.priorResolvedQuestion,
                    targetKind: .decision,
                    targetObjectID: Representative.newDecision,
                    evidence: linkEvidence()
                )
            ],
            derivedActionItemLinks: [
                DecisionDerivedActionItemLink(
                    decisionID: Representative.newDecision,
                    actionItemID: Representative.incomingMatchedActionItem,
                    evidence: linkEvidence()
                )
            ]
        )
    }

    /// A project whose stored work state is exactly the representative input's prior state, for
    /// the tests that must prove approved state is never mutated.
    static func representativeProject() -> Project {
        MeetingResultFixtures.project(
            id: projectID,
            meetings: [],
            decisions: [],
            actionItems: [
                approvedActionItem(id: Representative.priorMatchedActionItem, title: actionItemTitle),
                approvedActionItem(
                    id: Representative.priorOverdueActionItem,
                    title: unrelatedActionItemTitle,
                    dueDate: overdueDueDate
                )
            ],
            openQuestions: [
                approvedOpenQuestion(id: Representative.priorRevisedQuestion, question: openQuestionText),
                approvedOpenQuestion(id: Representative.priorResolvedQuestion, question: unrelatedOpenQuestionText)
            ],
            nextAgenda: []
        )
    }
}

/// Invariants that hold for *every* result the engine can produce, asserted from the outside.
///
/// These are the statements the contract makes unconditionally, so every scenario runs them. They
/// exist separately from the per-scenario expectations for a reason: a scenario test says "this
/// input produces that classification", while these say "whatever the classification, the row is
/// still explainable, still deterministic, and still inside the matrix". A regression that breaks
/// the second kind is the dangerous one, because it does not look like a wrong answer.
enum WorkStateTransitionContract {

    /// Kinds a caller may show without asking the user first. Section 4 of the contract.
    static let automaticTransitions: Set<WorkStateTransitionKind> = [.new, .same]

    static func assertInvariants(
        _ result: WorkStateTransitionEngineResult,
        for input: WorkStateTransitionEngineInput,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let knownObjectIDs = objectIDs(in: input)

        XCTAssertEqual(
            result.proposals.map(\.dedupKey),
            result.proposals.map(\.dedupKey).sorted(),
            "proposals must be sorted by dedupKey ascending",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(result.proposals.map(\.dedupKey)).count,
            result.proposals.count,
            "a dedup key may appear at most once in one result",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(result.proposals.map(\.id)).count,
            result.proposals.count,
            "ids are derived from dedup keys, so they must be unique too",
            file: file,
            line: line
        )

        for proposal in result.proposals {
            let label = "\(proposal.workStateKind.rawValue)/\(proposal.transitionKind.rawValue)"

            XCTAssertEqual(proposal.projectID, input.projectID, "\(label): wrong project", file: file, line: line)
            XCTAssertEqual(
                proposal.sourceMeetingID,
                input.sourceMeetingID,
                "\(label): wrong source meeting",
                file: file,
                line: line
            )
            XCTAssertEqual(
                proposal.reviewStatus,
                .pendingReview,
                "\(label): v0 never emits an already-reviewed row",
                file: file,
                line: line
            )
            XCTAssertTrue(
                WorkStateTransitionMatrix.supports(proposal.transitionKind, for: proposal.workStateKind),
                "\(label): outside the supported transition matrix",
                file: file,
                line: line
            )
            XCTAssertTrue(
                proposal.previousStateID != nil || proposal.currentObjectID != nil,
                "\(label): a proposal that references nothing cannot be reviewed",
                file: file,
                line: line
            )

            // Idempotency is recomputable from the row itself; that is what makes a second run
            // land on the same row instead of appending a duplicate.
            let expectedKey = WorkStateTransitionProposal.dedupKey(
                projectID: proposal.projectID,
                workStateKind: proposal.workStateKind,
                transitionKind: proposal.transitionKind,
                previousStateID: proposal.previousStateID,
                currentObjectID: proposal.currentObjectID
            )
            XCTAssertEqual(proposal.dedupKey, expectedKey, "\(label): dedup key not derived from its own fields", file: file, line: line)
            XCTAssertEqual(
                proposal.id,
                WorkStateTransitionProposal.deterministicID(forDedupKey: proposal.dedupKey),
                "\(label): id not derived from the dedup key",
                file: file,
                line: line
            )

            if let evidence = proposal.evidence {
                XCTAssertEqual(
                    evidence.meetingID,
                    input.sourceMeetingID,
                    "\(label): evidence must point into the meeting being processed",
                    file: file,
                    line: line
                )
            }

            if proposal.transitionKind == .new {
                XCTAssertNil(proposal.previousStateID, "\(label): a new item has no predecessor", file: file, line: line)
                XCTAssertNotNil(proposal.currentObjectID, "\(label): a new item must name the object", file: file, line: line)
                XCTAssertEqual(proposal.basis, .noPriorCandidate, "\(label): wrong basis for new", file: file, line: line)
            }

            if !proposal.requiresConfirmation {
                XCTAssertTrue(
                    automaticTransitions.contains(proposal.transitionKind),
                    "\(label): only new and same may skip confirmation",
                    file: file,
                    line: line
                )
            }

            XCTAssertEqual(
                proposal.reasons.map(\.rawValue),
                Array(Set(proposal.reasons.map(\.rawValue))).sorted(),
                "\(label): reasons must be sorted by rawValue and de-duplicated",
                file: file,
                line: line
            )

            XCTAssertEqual(
                proposal.relations.map(relationSortKey),
                proposal.relations.map(relationSortKey).sorted(),
                "\(label): relations must be deterministically sorted",
                file: file,
                line: line
            )

            for relation in proposal.relations {
                XCTAssertTrue(
                    knownObjectIDs.contains(relation.relatedObjectID),
                    "\(label): relation points at an object this input never contained",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Every object id the input could legitimately reference, prior or incoming.
    static func objectIDs(in input: WorkStateTransitionEngineInput) -> Set<UUID> {
        var ids = Set<UUID>()
        ids.formUnion(input.prior.decisions.map(\.id))
        ids.formUnion(input.prior.actionItems.map(\.id))
        ids.formUnion(input.prior.openQuestions.map(\.id))
        ids.formUnion(input.prior.agendaItems.map(\.id))
        ids.formUnion(input.incoming.decisions.map(\.id))
        ids.formUnion(input.incoming.actionItems.map(\.id))
        ids.formUnion(input.incoming.openQuestions.map(\.id))
        ids.formUnion(input.incoming.agendaItems.map(\.id))
        return ids
    }

    static func relationSortKey(_ relation: WorkStateTransitionRelation) -> String {
        "\(relation.kind.rawValue)|\(relation.relatedKind.rawValue)|\(relation.relatedObjectID.uuidString)"
    }
}
