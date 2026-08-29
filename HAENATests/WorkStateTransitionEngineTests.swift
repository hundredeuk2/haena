import XCTest
@testable import HAENA

/// Every test here asserts one boundary of the transition contract, and nothing else. The engine is
/// a pure function, so each case is "this exact input produces exactly these statements" — there is
/// no clock, no store, and no ordering-by-luck to work around.
final class WorkStateTransitionEngineTests: XCTestCase {

    // MARK: - Fixed identity

    private static let projectID = UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!
    private static let otherProjectID = UUID(uuidString: "0000000A-0000-0000-0000-000000000002")!
    private static let meetingID = UUID(uuidString: "0000000A-0000-0000-0000-000000000003")!
    private static let priorMeetingID = UUID(uuidString: "0000000A-0000-0000-0000-000000000004")!
    private static let segmentID = UUID(uuidString: "0000000A-0000-0000-0000-000000000005")!

    private static let priorDecisionID = UUID(uuidString: "0000000A-0000-0000-0000-000000000101")!
    private static let secondPriorDecisionID = UUID(uuidString: "0000000A-0000-0000-0000-000000000102")!
    private static let incomingDecisionID = UUID(uuidString: "0000000A-0000-0000-0000-000000000111")!
    private static let priorActionItemID = UUID(uuidString: "0000000A-0000-0000-0000-000000000201")!
    private static let incomingActionItemID = UUID(uuidString: "0000000A-0000-0000-0000-000000000211")!
    private static let priorOpenQuestionID = UUID(uuidString: "0000000A-0000-0000-0000-000000000301")!
    private static let incomingOpenQuestionID = UUID(uuidString: "0000000A-0000-0000-0000-000000000311")!
    private static let priorAgendaItemID = UUID(uuidString: "0000000A-0000-0000-0000-000000000401")!
    private static let incomingAgendaItemID = UUID(uuidString: "0000000A-0000-0000-0000-000000000411")!
    private static let unknownID = UUID(uuidString: "0000000A-0000-0000-0000-000000000999")!

    /// When the meeting happened. Lateness is judged against this, never against `now`.
    private static let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// Deliberately later than `occurredAt` so a test can tell the two apart in `createdAt`.
    private static let now = Date(timeIntervalSince1970: 1_700_009_999)
    private static let overdue = Date(timeIntervalSince1970: 1_699_000_000)

    // MARK: - `new`

    func testNewObjectWithNoPriorStateProducesOneAutomaticNewProposal() {
        let fresh = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let result = run(incoming: ValidatedWorkState(decisions: [fresh]))

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.proposals.count, 1)
        let proposal = result.proposals[0]
        XCTAssertEqual(proposal.workStateKind, .decision)
        XCTAssertEqual(proposal.transitionKind, .new)
        XCTAssertEqual(proposal.basis, .noPriorCandidate)
        XCTAssertNil(proposal.previousStateID)
        XCTAssertEqual(proposal.currentObjectID, Self.incomingDecisionID)
        XCTAssertEqual(proposal.sourceMeetingID, Self.meetingID)
        XCTAssertEqual(proposal.evidence, TransitionEvidencePointer(meetingID: Self.meetingID, transcriptSegmentID: Self.segmentID))
        XCTAssertEqual(proposal.reasons, [])
        XCTAssertFalse(proposal.requiresConfirmation, "recording a brand-new item changes no approved state")
        XCTAssertEqual(proposal.reviewStatus, .pendingReview)
        XCTAssertEqual(proposal.createdAt, Self.now)
    }

    // MARK: - `same`

    func testIdenticalPriorObjectProducesAnAutomaticSameProposal() {
        // Case, padding, and terminal punctuation are rendering differences, not identity ones.
        let prior = decision(id: Self.priorDecisionID, statement: "Ship the beta in March.", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(id: Self.incomingDecisionID, statement: "  ship  the BETA in march  ", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [prior]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals[0].transitionKind, .same)
        XCTAssertEqual(result.proposals[0].basis, .exactNormalizedTextMatch)
        XCTAssertEqual(result.proposals[0].previousStateID, Self.priorDecisionID)
        XCTAssertEqual(result.proposals[0].reasons, [])
        XCTAssertFalse(result.proposals[0].requiresConfirmation)
    }

    // MARK: - `changed`

    func testSingleNearMatchProducesAChangedProposalThatAlwaysRequiresConfirmation() {
        let prior = decision(id: Self.priorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [prior]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals[0].transitionKind, .changed)
        XCTAssertEqual(result.proposals[0].basis, .nearTextMatch)
        XCTAssertEqual(result.proposals[0].previousStateID, Self.priorDecisionID)
        XCTAssertEqual(result.proposals[0].reasons, [.similarityOnly])
        XCTAssertTrue(result.proposals[0].requiresConfirmation, "similarity alone must never auto-confirm")
    }

    // MARK: - Ambiguity

    func testTwoPriorCandidatesProduceOneConfirmationEachAndNeverANewProposal() {
        let first = decision(id: Self.priorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let second = decision(id: Self.secondPriorDecisionID, statement: "Ship the beta in April", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [first, second]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        XCTAssertEqual(result.proposals.count, 2)
        XCTAssertTrue(result.proposals.allSatisfy { $0.transitionKind == .changed })
        XCTAssertTrue(result.proposals.allSatisfy { $0.requiresConfirmation })
        XCTAssertTrue(result.proposals.allSatisfy { $0.reasons == [.ambiguousPriorCandidates, .similarityOnly] })
        XCTAssertEqual(
            Set(result.proposals.compactMap(\.previousStateID)),
            [Self.priorDecisionID, Self.secondPriorDecisionID]
        )
        XCTAssertFalse(
            result.proposals.contains { $0.transitionKind == .new },
            "inventing a new item alongside unresolved candidates is the duplicate this feature prevents"
        )

        let group = try? XCTUnwrap(result.ambiguousMatchGroups.first)
        XCTAssertEqual(result.ambiguousMatchGroups.count, 1)
        XCTAssertEqual(group?.incomingObjectID, Self.incomingDecisionID)
        XCTAssertEqual(
            group?.priorCandidateIDs,
            [Self.priorDecisionID, Self.secondPriorDecisionID].sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        )
        XCTAssertTrue(group?.availableSelections.contains(.new) == true)
        XCTAssertTrue(group?.accepts(.new) == true)
        XCTAssertTrue(group?.accepts(.priorCandidate(Self.priorDecisionID)) == true)
    }

    func testAmbiguityGroupIdentityDoesNotDependOnCandidateOrder() throws {
        let first = decision(id: Self.priorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let second = decision(id: Self.secondPriorDecisionID, statement: "Ship the beta in April", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let forward = run(
            prior: snapshot(decisions: [first, second]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )
        let reversed = run(
            prior: snapshot(decisions: [second, first]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        let forwardGroup = try XCTUnwrap(forward.ambiguousMatchGroups.first)
        let reversedGroup = try XCTUnwrap(reversed.ambiguousMatchGroups.first)
        XCTAssertEqual(forwardGroup.id, reversedGroup.id)
        XCTAssertEqual(forwardGroup.dedupKey, reversedGroup.dedupKey)
        XCTAssertEqual(forwardGroup.priorCandidateIDs, reversedGroup.priorCandidateIDs)
    }

    func testAnExactMatchAlongsideANearMatchIsTreatedAsAmbiguousRatherThanAsSame() {
        let exact = decision(id: Self.priorDecisionID, statement: "Ship the beta in March", status: .confirmed, meeting: Self.priorMeetingID)
        let near = decision(id: Self.secondPriorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [exact, near]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        XCTAssertEqual(result.proposals.count, 2)
        XCTAssertFalse(
            result.proposals.contains { $0.transitionKind == .same },
            "an exact candidate must not be pre-picked as the winner while another candidate stands"
        )
        XCTAssertTrue(result.proposals.allSatisfy { $0.transitionKind == .changed && $0.requiresConfirmation })

        let exactRow = try? XCTUnwrap(result.proposals.first { $0.previousStateID == Self.priorDecisionID })
        XCTAssertEqual(exactRow?.basis, .exactNormalizedTextMatch)
        XCTAssertEqual(exactRow?.reasons, [.ambiguousPriorCandidates])

        let nearRow = try? XCTUnwrap(result.proposals.first { $0.previousStateID == Self.secondPriorDecisionID })
        XCTAssertEqual(nearRow?.basis, .nearTextMatch)
        XCTAssertEqual(nearRow?.reasons, [.ambiguousPriorCandidates, .similarityOnly])
    }

    // MARK: - `completed`

    func testCompletedProgressSignalAddsACompletedProposalAlongsideTheMatchProposal() {
        let prior = actionItem(id: Self.priorActionItemID, title: "Draft the release notes", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = actionItem(id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence())
        let signal = WorkStateProgressSignal(kind: .completed, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence())

        let result = run(
            prior: snapshot(actionItems: [prior]),
            incoming: ValidatedWorkState(actionItems: [incoming]),
            progressSignals: [signal]
        )

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.proposals.count, 2)

        let same = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .same })
        XCTAssertEqual(same?.previousStateID, Self.priorActionItemID)
        XCTAssertEqual(same?.requiresConfirmation, false)

        let completed = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .completed })
        XCTAssertEqual(completed?.basis, .structuredProgressSignal)
        XCTAssertNil(completed?.progressDisposition)
        XCTAssertEqual(completed?.previousStateID, Self.priorActionItemID)
        XCTAssertEqual(completed?.currentObjectID, Self.incomingActionItemID)
        XCTAssertEqual(completed?.reasons, [.stateChangeRequiresApproval])
        XCTAssertEqual(completed?.requiresConfirmation, true)
        XCTAssertNotEqual(same?.dedupKey, completed?.dedupKey, "both statements are true about the same pair")
    }

    /// The case the incoming-only contract could not express: the meeting reports on work that
    /// already exists and extracts no task of its own, so all three kinds have to reach the prior
    /// canonical item with no current object at all.
    func testPriorTargetProgressSignalsTransitionThePriorItemWithNoCurrentObject() {
        let prior = actionItem(id: Self.priorActionItemID, title: "Draft the release notes", status: .confirmed, meeting: Self.priorMeetingID)

        for (kind, transition, disposition) in [
            (WorkStateProgressSignalKind.completed, WorkStateTransitionKind.completed, nil as WorkStateTransitionProgressDisposition?),
            (.deferred, .delayed, .deferred),
            (.blocked, .delayed, .blocked)
        ] {
            let result = run(
                prior: snapshot(actionItems: [prior]),
                progressSignals: [
                    WorkStateProgressSignal(
                        kind: kind,
                        target: .priorActionItem(Self.priorActionItemID),
                        evidence: sourceEvidence()
                    )
                ]
            )

            XCTAssertTrue(result.refusals.isEmpty, "\(kind)")
            XCTAssertEqual(result.proposals.count, 1, "\(kind): a status report creates no duplicate")
            XCTAssertEqual(result.proposals[0].transitionKind, transition, "\(kind)")
            XCTAssertEqual(result.proposals[0].basis, .structuredProgressSignal, "\(kind)")
            XCTAssertEqual(result.proposals[0].previousStateID, Self.priorActionItemID, "\(kind)")
            XCTAssertNil(result.proposals[0].currentObjectID, "\(kind)")
            XCTAssertEqual(result.proposals[0].progressDisposition, disposition, "\(kind)")
            XCTAssertNotNil(result.proposals[0].evidence, "\(kind): the signal's own citation carries it")
            XCTAssertTrue(result.proposals[0].requiresConfirmation, "\(kind)")
        }
    }

    func testDirectDecisionChangeLinkOutranksTextMatchingAndNamesThePriorDecision() {
        let prior = decision(id: Self.priorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = decision(
            id: Self.incomingDecisionID,
            statement: "Keep local storage but add an export path",
            evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(decisions: [prior]),
            incoming: ValidatedWorkState(decisions: [incoming]),
            decisionChangeLinks: [
                DecisionChangeLink(
                    priorDecisionID: Self.priorDecisionID,
                    incomingDecisionID: Self.incomingDecisionID,
                    evidence: sourceEvidence()
                )
            ]
        )

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertTrue(result.ambiguousMatchGroups.isEmpty)
        XCTAssertEqual(result.proposals.count, 1, "the named prior replaces the text matcher's own answer")
        XCTAssertEqual(result.proposals[0].transitionKind, .changed)
        XCTAssertEqual(result.proposals[0].basis, .structuredDecisionChangeLink)
        XCTAssertEqual(result.proposals[0].previousStateID, Self.priorDecisionID)
        XCTAssertEqual(result.proposals[0].currentObjectID, Self.incomingDecisionID)
        XCTAssertTrue(result.proposals[0].requiresConfirmation)
    }

    // MARK: - `delayed`

    func testOverdueApprovedDueDateProducesADelayedProposalWithNoCurrentObject() {
        let prior = actionItem(
            id: Self.priorActionItemID, title: "Draft the release notes",
            status: .confirmed, dueDate: Self.overdue, meeting: Self.priorMeetingID
        )

        let result = run(prior: snapshot(actionItems: [prior]))

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals[0].transitionKind, .delayed)
        XCTAssertEqual(result.proposals[0].basis, .overdueApprovedDueDate)
        XCTAssertEqual(result.proposals[0].previousStateID, Self.priorActionItemID)
        XCTAssertNil(result.proposals[0].currentObjectID, "lateness is a fact about stored state, not about this meeting")
        XCTAssertNil(result.proposals[0].evidence)
        XCTAssertNil(result.proposals[0].progressDisposition)
        XCTAssertEqual(result.proposals[0].reasons, [.stateChangeRequiresApproval])
        XCTAssertTrue(result.proposals[0].requiresConfirmation)
    }

    func testDeferredProgressSignalProducesADelayedProposalBackedByTheSignal() {
        let prior = actionItem(id: Self.priorActionItemID, title: "Draft the release notes", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = actionItem(id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence())
        let signal = WorkStateProgressSignal(kind: .deferred, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence())

        let result = run(
            prior: snapshot(actionItems: [prior]),
            incoming: ValidatedWorkState(actionItems: [incoming]),
            progressSignals: [signal]
        )

        let delayed = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .delayed })
        XCTAssertEqual(delayed?.basis, .structuredProgressSignal)
        XCTAssertEqual(delayed?.progressDisposition, .deferred)
        XCTAssertEqual(delayed?.previousStateID, Self.priorActionItemID)
        XCTAssertEqual(delayed?.currentObjectID, Self.incomingActionItemID)
        XCTAssertEqual(delayed?.evidence, TransitionEvidencePointer(meetingID: Self.meetingID, transcriptSegmentID: Self.segmentID))
        XCTAssertEqual(delayed?.reasons, [.stateChangeRequiresApproval])
        XCTAssertTrue(delayed?.requiresConfirmation == true)
    }

    func testBlockedProgressSignalPreservesBlockedDisposition() {
        let prior = actionItem(
            id: Self.priorActionItemID, title: "Draft the release notes",
            status: .confirmed, meeting: Self.priorMeetingID
        )
        let incoming = actionItem(
            id: Self.incomingActionItemID, title: "Draft the release notes",
            evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(actionItems: [prior]),
            incoming: ValidatedWorkState(actionItems: [incoming]),
            progressSignals: [WorkStateProgressSignal(
                kind: .blocked,
                actionItemID: Self.incomingActionItemID,
                evidence: sourceEvidence()
            )]
        )

        let delayed = result.proposals.first { $0.transitionKind == .delayed }
        XCTAssertEqual(delayed?.progressDisposition, .blocked)
        XCTAssertTrue(result.proposals.allSatisfy(\.hasValidProgressDispositionContract))
    }

    func testAnOverdueItemThatIsAlsoExplicitlyDeferredYieldsOneDelayWithTheSignalBasis() {
        let prior = actionItem(
            id: Self.priorActionItemID, title: "Draft the release notes",
            status: .confirmed, dueDate: Self.overdue, meeting: Self.priorMeetingID
        )
        let incoming = actionItem(id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence())
        let signal = WorkStateProgressSignal(kind: .deferred, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence())

        let result = run(
            prior: snapshot(actionItems: [prior]),
            incoming: ValidatedWorkState(actionItems: [incoming]),
            progressSignals: [signal]
        )

        let delayed = result.proposals.filter { $0.transitionKind == .delayed }
        XCTAssertEqual(delayed.count, 1, "two bases for one prior item collapse to one statement")
        XCTAssertEqual(delayed[0].basis, .structuredProgressSignal, "the explicit statement is the better explanation")
        XCTAssertEqual(delayed[0].currentObjectID, Self.incomingActionItemID)
        XCTAssertNotNil(delayed[0].evidence)
    }

    // MARK: - `resolved`

    func testOpenQuestionResolvedByADecisionCarriesAResolvedByRelation() {
        let question = openQuestion(id: Self.priorOpenQuestionID, question: "Who owns the rollout?", reviewedAt: Self.overdue, meeting: Self.priorMeetingID)
        let target = decision(id: Self.incomingDecisionID, statement: "Platform owns the rollout", evidence: sourceEvidence())
        let link = OpenQuestionResolutionLink(
            priorOpenQuestionID: Self.priorOpenQuestionID, targetKind: .decision,
            targetObjectID: Self.incomingDecisionID, evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(openQuestions: [question]),
            incoming: ValidatedWorkState(decisions: [target]),
            resolutionLinks: [link]
        )

        XCTAssertTrue(result.refusals.isEmpty)
        let resolved = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .resolved })
        XCTAssertEqual(resolved?.workStateKind, .openQuestion)
        XCTAssertEqual(resolved?.basis, .structuredResolutionLink)
        XCTAssertEqual(resolved?.previousStateID, Self.priorOpenQuestionID)
        XCTAssertEqual(resolved?.currentObjectID, Self.incomingDecisionID)
        XCTAssertEqual(resolved?.reasons, [.stateChangeRequiresApproval])
        XCTAssertTrue(resolved?.requiresConfirmation == true)
        XCTAssertEqual(
            resolved?.relations,
            [WorkStateTransitionRelation(kind: .resolvedBy, relatedKind: .decision, relatedObjectID: Self.incomingDecisionID)]
        )
    }

    func testOpenQuestionResolvedByAnActionItemCarriesAResolvedByRelation() {
        let question = openQuestion(id: Self.priorOpenQuestionID, question: "Who owns the rollout?", reviewedAt: Self.overdue, meeting: Self.priorMeetingID)
        let target = actionItem(id: Self.incomingActionItemID, title: "Publish the rollout owner list", evidence: sourceEvidence())
        let link = OpenQuestionResolutionLink(
            priorOpenQuestionID: Self.priorOpenQuestionID, targetKind: .actionItem,
            targetObjectID: Self.incomingActionItemID, evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(openQuestions: [question]),
            incoming: ValidatedWorkState(actionItems: [target]),
            resolutionLinks: [link]
        )

        let resolved = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .resolved })
        XCTAssertEqual(resolved?.workStateKind, .openQuestion)
        XCTAssertEqual(
            resolved?.relations,
            [WorkStateTransitionRelation(kind: .resolvedBy, relatedKind: .actionItem, relatedObjectID: Self.incomingActionItemID)]
        )
    }

    func testOpenQuestionTargetedAtAnAgendaItemUsesTheCarriedToAgendaRelation() {
        let question = openQuestion(id: Self.priorOpenQuestionID, question: "Who owns the rollout?", reviewedAt: Self.overdue, meeting: Self.priorMeetingID)
        let target = agendaItem(id: Self.incomingAgendaItemID, title: "Decide the rollout owner", evidence: sourceEvidence())
        let link = OpenQuestionResolutionLink(
            priorOpenQuestionID: Self.priorOpenQuestionID, targetKind: .agendaItem,
            targetObjectID: Self.incomingAgendaItemID, evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(openQuestions: [question]),
            incoming: ValidatedWorkState(agendaItems: [target]),
            resolutionLinks: [link]
        )

        let resolved = try? XCTUnwrap(result.proposals.first { $0.transitionKind == .resolved })
        XCTAssertEqual(resolved?.workStateKind, .openQuestion, "an agenda hand-off is still an open-question transition")
        XCTAssertEqual(
            resolved?.relations,
            [WorkStateTransitionRelation(kind: .carriedToAgenda, relatedKind: .agendaItem, relatedObjectID: Self.incomingAgendaItemID)]
        )
    }

    // MARK: - `derivedFrom`

    func testDecisionDerivedLinkAnnotatesEveryProposalForThatActionItemAndCreatesNone() {
        let priorTask = actionItem(id: Self.priorActionItemID, title: "Draft the release notes", status: .confirmed, meeting: Self.priorMeetingID)
        let sourceDecision = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())
        let task = actionItem(id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence())
        let signal = WorkStateProgressSignal(kind: .completed, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence())
        let link = DecisionDerivedActionItemLink(
            decisionID: Self.incomingDecisionID, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence()
        )

        let result = run(
            prior: snapshot(actionItems: [priorTask]),
            incoming: ValidatedWorkState(decisions: [sourceDecision], actionItems: [task]),
            progressSignals: [signal],
            derivedActionItemLinks: [link]
        )

        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.proposals.count, 3, "provenance annotates existing statements; it never adds one")

        let expected = WorkStateTransitionRelation(kind: .derivedFrom, relatedKind: .decision, relatedObjectID: Self.incomingDecisionID)
        let taskProposals = result.proposals.filter { $0.workStateKind == .actionItem }
        XCTAssertEqual(taskProposals.count, 2)
        XCTAssertTrue(taskProposals.allSatisfy { $0.relations == [expected] })
        XCTAssertEqual(Set(taskProposals.map(\.transitionKind)), [.same, .completed])

        let decisionProposal = try? XCTUnwrap(result.proposals.first { $0.workStateKind == .decision })
        XCTAssertEqual(decisionProposal?.relations, [])
    }

    // MARK: - Admission

    func testIncomingObjectFromAnotherProjectIsRefusedAndNeverProposed() {
        let foreign = decision(
            id: Self.incomingDecisionID, statement: "Ship the beta in March",
            projectID: Self.otherProjectID, evidence: sourceEvidence()
        )

        let result = run(incoming: ValidatedWorkState(decisions: [foreign]))

        XCTAssertTrue(result.proposals.isEmpty)
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals[0].reason, .crossProjectCandidate)
        XCTAssertEqual(result.refusals[0].workStateKind, .decision)
        XCTAssertEqual(result.refusals[0].currentObjectID, Self.incomingDecisionID)
    }

    func testPriorObjectFromAnotherProjectNeverBecomesACandidate() {
        // Approved, and textually identical — the only thing keeping it out is project membership,
        // which is checked before approval is even consulted.
        let foreignPrior = decision(
            id: Self.priorDecisionID, statement: "Ship the beta in March",
            status: .confirmed, projectID: Self.otherProjectID, meeting: Self.priorMeetingID
        )
        let incoming = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [foreignPrior]),
            incoming: ValidatedWorkState(decisions: [incoming])
        )

        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals[0].transitionKind, .new)
        XCTAssertNil(result.proposals[0].previousStateID)
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals[0].reason, .crossProjectCandidate)
        XCTAssertEqual(result.refusals[0].previousStateID, Self.priorDecisionID)
    }

    func testIncomingObjectWithoutEvidenceIsRefused() {
        let ungrounded = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: nil)

        let result = run(incoming: ValidatedWorkState(decisions: [ungrounded]))

        XCTAssertTrue(result.proposals.isEmpty)
        XCTAssertEqual(result.refusals.map(\.reason), [.missingEvidence])
    }

    func testIncomingEvidenceCitingAnotherMeetingIsRefused() {
        let elsewhere = decision(
            id: Self.incomingDecisionID, statement: "Ship the beta in March",
            evidence: sourceEvidence(meeting: Self.priorMeetingID)
        )

        let result = run(incoming: ValidatedWorkState(decisions: [elsewhere]))

        XCTAssertTrue(result.proposals.isEmpty)
        XCTAssertEqual(result.refusals.map(\.reason), [.evidenceNotInSourceMeeting])
    }

    func testUnapprovedPriorItemsAreNotCandidates() {
        let unconfirmed = decision(id: Self.priorDecisionID, statement: "Ship the beta in March", status: .proposed, meeting: Self.priorMeetingID)
        // `.open` with no `reviewedAt` is an unreviewed extraction, not approved prior state.
        let unreviewed = openQuestion(id: Self.priorOpenQuestionID, question: "Who owns the rollout?", reviewedAt: nil, meeting: Self.priorMeetingID)
        let incomingDecision = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())
        let incomingQuestion = openQuestion(id: Self.incomingOpenQuestionID, question: "Who owns the rollout?", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(decisions: [unconfirmed], openQuestions: [unreviewed]),
            incoming: ValidatedWorkState(decisions: [incomingDecision], openQuestions: [incomingQuestion])
        )

        XCTAssertEqual(result.proposals.count, 2)
        XCTAssertTrue(result.proposals.allSatisfy { $0.transitionKind == .new && $0.previousStateID == nil })
        XCTAssertEqual(result.refusals.count, 2)
        XCTAssertTrue(result.refusals.allSatisfy { $0.reason == .priorItemNotApproved })
    }

    // MARK: - Assignee attribution

    func testUnresolvedAssigneeAttributionDowngradesAnOtherwiseAutomaticSame() {
        let prior = actionItem(id: Self.priorActionItemID, title: "Draft the release notes", status: .confirmed, meeting: Self.priorMeetingID)
        let incoming = actionItem(
            id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence(),
            attribution: AssigneeAttribution(
                basis: .explicitName, reference: "Jamie", speakerLabel: nil,
                resolution: .ambiguousParticipantMatch
            )
        )

        let result = run(
            prior: snapshot(actionItems: [prior]),
            incoming: ValidatedWorkState(actionItems: [incoming])
        )

        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals[0].transitionKind, .same, "attribution is never a matching signal")
        XCTAssertEqual(result.proposals[0].previousStateID, Self.priorActionItemID)
        XCTAssertTrue(result.proposals[0].requiresConfirmation)
        XCTAssertEqual(result.proposals[0].reasons, [.unresolvedAssigneeAttribution])
    }

    // MARK: - Transition matrix

    func testAgendaItemNearMatchIsRefusedBecauseAgendaItemsCannotExpressChanged() {
        let prior = agendaItem(
            id: Self.priorAgendaItemID, title: "Review the beta rollout plan",
            evidence: sourceEvidence(meeting: Self.priorMeetingID), reviewedAt: Self.overdue
        )
        let incoming = agendaItem(id: Self.incomingAgendaItemID, title: "Review the beta rollout timeline", evidence: sourceEvidence())

        let result = run(
            prior: snapshot(agendaItems: [prior]),
            incoming: ValidatedWorkState(agendaItems: [incoming])
        )

        XCTAssertTrue(result.proposals.isEmpty, "a `changed` row must not be manufactured for the weakest identity of the four")
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals[0].reason, .unsupportedTransitionForKind)
        XCTAssertEqual(result.refusals[0].workStateKind, .agendaItem)
        XCTAssertEqual(result.refusals[0].attemptedTransition, .changed)
        XCTAssertEqual(result.refusals[0].previousStateID, Self.priorAgendaItemID)
    }

    // MARK: - Structured links pointing nowhere

    func testStructuredLinkPointingAtANonexistentObjectIsRefused() {
        let target = decision(id: Self.incomingDecisionID, statement: "Platform owns the rollout", evidence: sourceEvidence())
        let dangling = OpenQuestionResolutionLink(
            priorOpenQuestionID: Self.unknownID, targetKind: .decision,
            targetObjectID: Self.incomingDecisionID, evidence: sourceEvidence()
        )

        let result = run(
            incoming: ValidatedWorkState(decisions: [target]),
            resolutionLinks: [dangling]
        )

        XCTAssertFalse(result.proposals.contains { $0.transitionKind == .resolved })
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals[0].reason, .unknownReferencedObject)
        XCTAssertEqual(result.refusals[0].previousStateID, Self.unknownID)
    }

    // MARK: - Determinism

    func testGeneratingTwiceOverTheSameInputProducesAnIdenticalResult() {
        let input = richInput()

        let first = WorkStateTransitionEngine.generate(input, now: Self.now)
        let second = WorkStateTransitionEngine.generate(input, now: Self.now)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.proposals.map(\.id), second.proposals.map(\.id))
        XCTAssertEqual(first.proposals.map(\.dedupKey), second.proposals.map(\.dedupKey))
        XCTAssertEqual(first.proposals.count, second.proposals.count)
    }

    func testOutputIsOrderedByDedupKeyWithSortedReasonsAndRelations() {
        let result = WorkStateTransitionEngine.generate(richInput(), now: Self.now)

        XCTAssertEqual(result.proposals.count, 7)
        XCTAssertEqual(
            result.proposals.map(\.dedupKey),
            result.proposals.map(\.dedupKey).sorted(),
            "persisted order is the contract, not an accident of traversal"
        )
        XCTAssertEqual(Set(result.proposals.map(\.dedupKey)).count, result.proposals.count)

        for proposal in result.proposals {
            XCTAssertEqual(
                proposal.id,
                WorkStateTransitionProposal.deterministicID(forDedupKey: proposal.dedupKey),
                "identity must be derived from the dedup key, never minted"
            )
            XCTAssertEqual(proposal.reasons, proposal.reasons.sorted { $0.rawValue < $1.rawValue })
            XCTAssertEqual(Set(proposal.reasons.map(\.rawValue)).count, proposal.reasons.count)
            XCTAssertEqual(
                proposal.relations.map { [$0.kind.rawValue, $0.relatedKind.rawValue, $0.relatedObjectID.uuidString] },
                proposal.relations
                    .map { [$0.kind.rawValue, $0.relatedKind.rawValue, $0.relatedObjectID.uuidString] }
                    .sorted { lhs, rhs in lhs.lexicographicallyPrecedes(rhs) }
            )
        }
    }

    // MARK: - Input construction

    /// One run that exercises every emitting rule at once, so the ordering and determinism tests are
    /// not asserting over a trivially short list.
    private func richInput() -> WorkStateTransitionEngineInput {
        let priorDecision = decision(id: Self.priorDecisionID, statement: "Ship the beta in February", status: .confirmed, meeting: Self.priorMeetingID)
        let priorTask = actionItem(
            id: Self.priorActionItemID, title: "Draft the release notes",
            status: .confirmed, dueDate: Self.overdue, meeting: Self.priorMeetingID
        )
        let priorQuestion = openQuestion(id: Self.priorOpenQuestionID, question: "Who owns the rollout?", reviewedAt: Self.overdue, meeting: Self.priorMeetingID)
        let priorAgenda = agendaItem(id: Self.priorAgendaItemID, title: "Review the rollout plan", reviewedAt: Self.overdue)

        let newDecision = decision(id: Self.incomingDecisionID, statement: "Ship the beta in March", evidence: sourceEvidence())
        let newTask = actionItem(id: Self.incomingActionItemID, title: "Draft the release notes", evidence: sourceEvidence())
        let newQuestion = openQuestion(id: Self.incomingOpenQuestionID, question: "What is the pricing?", evidence: sourceEvidence())
        let newAgenda = agendaItem(id: Self.incomingAgendaItemID, title: "Review the rollout plan", evidence: sourceEvidence())

        return WorkStateTransitionEngineInput(
            projectID: Self.projectID,
            sourceMeetingID: Self.meetingID,
            occurredAt: Self.occurredAt,
            prior: snapshot(
                decisions: [priorDecision], actionItems: [priorTask],
                openQuestions: [priorQuestion], agendaItems: [priorAgenda]
            ),
            incoming: ValidatedWorkState(
                decisions: [newDecision], actionItems: [newTask],
                openQuestions: [newQuestion], agendaItems: [newAgenda]
            ),
            progressSignals: [
                WorkStateProgressSignal(kind: .completed, actionItemID: Self.incomingActionItemID, evidence: sourceEvidence())
            ],
            resolutionLinks: [
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: Self.priorOpenQuestionID, targetKind: .decision,
                    targetObjectID: Self.incomingDecisionID, evidence: sourceEvidence()
                )
            ],
            derivedActionItemLinks: [
                DecisionDerivedActionItemLink(
                    decisionID: Self.incomingDecisionID, actionItemID: Self.incomingActionItemID,
                    evidence: sourceEvidence()
                )
            ]
        )
    }

    private func run(
        prior: ApprovedWorkStateSnapshot? = nil,
        incoming: ValidatedWorkState = ValidatedWorkState(),
        progressSignals: [WorkStateProgressSignal] = [],
        resolutionLinks: [OpenQuestionResolutionLink] = [],
        derivedActionItemLinks: [DecisionDerivedActionItemLink] = [],
        decisionChangeLinks: [DecisionChangeLink] = []
    ) -> WorkStateTransitionEngineResult {
        WorkStateTransitionEngine.generate(
            WorkStateTransitionEngineInput(
                projectID: Self.projectID,
                sourceMeetingID: Self.meetingID,
                occurredAt: Self.occurredAt,
                prior: prior ?? snapshot(),
                incoming: incoming,
                progressSignals: progressSignals,
                resolutionLinks: resolutionLinks,
                derivedActionItemLinks: derivedActionItemLinks,
                decisionChangeLinks: decisionChangeLinks
            ),
            now: Self.now
        )
    }

    // MARK: - Fixtures

    private func sourceEvidence(meeting: UUID? = nil, segment: UUID? = nil) -> EvidenceReference {
        EvidenceReference(
            meetingID: meeting ?? Self.meetingID,
            transcriptSegmentID: segment ?? Self.segmentID,
            quote: "a grounded line"
        )
    }

    private func snapshot(
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        agendaItems: [AgendaItem] = []
    ) -> ApprovedWorkStateSnapshot {
        ApprovedWorkStateSnapshot(
            projectID: Self.projectID,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            agendaItems: agendaItems
        )
    }

    private func decision(
        id: UUID,
        statement: String,
        status: DecisionStatus = .proposed,
        projectID: UUID? = nil,
        evidence: EvidenceReference? = nil,
        meeting: UUID? = nil
    ) -> Decision {
        Decision(
            id: id,
            projectID: projectID ?? Self.projectID,
            meetingID: meeting ?? Self.meetingID,
            statement: statement,
            rationale: nil,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.9),
            createdAt: Self.occurredAt,
            updatedAt: Self.occurredAt
        )
    }

    private func actionItem(
        id: UUID,
        title: String,
        status: ActionItemStatus = .proposed,
        dueDate: Date? = nil,
        projectID: UUID? = nil,
        evidence: EvidenceReference? = nil,
        attribution: AssigneeAttribution? = nil,
        meeting: UUID? = nil
    ) -> ActionItem {
        ActionItem(
            id: id,
            projectID: projectID ?? Self.projectID,
            meetingID: meeting ?? Self.meetingID,
            title: title,
            details: nil,
            assigneeID: nil,
            dueDate: dueDate,
            status: status,
            evidence: evidence,
            confidence: Confidence(0.9),
            proposedAssigneeAttribution: attribution,
            createdAt: Self.occurredAt,
            updatedAt: Self.occurredAt
        )
    }

    private func openQuestion(
        id: UUID,
        question: String,
        projectID: UUID? = nil,
        evidence: EvidenceReference? = nil,
        reviewedAt: Date? = nil,
        meeting: UUID? = nil
    ) -> OpenQuestion {
        OpenQuestion(
            id: id,
            projectID: projectID ?? Self.projectID,
            meetingID: meeting ?? Self.meetingID,
            question: question,
            status: .open,
            evidence: evidence,
            confidence: Confidence(0.9),
            createdAt: Self.occurredAt,
            resolvedAt: nil,
            reviewedAt: reviewedAt
        )
    }

    private func agendaItem(
        id: UUID,
        title: String,
        projectID: UUID? = nil,
        evidence: EvidenceReference? = nil,
        reviewedAt: Date? = nil
    ) -> AgendaItem {
        AgendaItem(
            id: id,
            projectID: projectID ?? Self.projectID,
            title: title,
            reason: "carried over",
            sourceMeetingID: Self.meetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: Self.occurredAt,
            evidence: evidence,
            confidence: Confidence(0.9),
            reviewedAt: reviewedAt
        )
    }
}
