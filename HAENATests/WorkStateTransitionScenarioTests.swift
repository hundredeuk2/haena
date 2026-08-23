import XCTest
@testable import HAENA

/// The end-to-end scenario matrix for Meeting Continuity v0.
///
/// These are black-box contract tests. Every assertion is about something a caller — and in
/// particular the follow-up Manual Continuity Brief — can observe on a returned proposal:
/// which transition it claims, what it points at, why, and whether a human has to say yes.
/// Nothing here reaches into a private helper or pins an internal threshold, because the promise
/// the feature makes to a user is not "the similarity score was 0.8"; it is "a revised decision is
/// never silently merged, and a duplicate never appears after a restart".
///
/// One test per boundary in the mandated matrix, in matrix order. Where a boundary has a natural
/// control — the same input with the one thing that matters flipped — the control lives in the
/// same test, because a containment assertion with no counterexample passes for the wrong reason.
final class WorkStateTransitionScenarioTests: XCTestCase {

    private typealias Fixtures = WorkStateTransitionFixtures

    private var testDirectory: URL!

    override func setUpWithError() throws {
        // A unique subdirectory under the system temp directory — never Application Support — so
        // an on-disk test can never see, or be seen by, real user data.
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-WorkStateTransition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private func fileURL(_ name: String) -> URL {
        testDirectory.appendingPathComponent(name)
    }

    // MARK: - Helpers

    /// Runs the engine and asserts the universal invariants at the same time, so no scenario can
    /// pass while producing a row that is unexplainable, unsorted, or outside the matrix.
    private func generate(
        _ input: WorkStateTransitionEngineInput,
        now: Date = WorkStateTransitionFixtures.generatedAt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkStateTransitionEngineResult {
        let result = WorkStateTransitionEngine.generate(input, now: now)
        WorkStateTransitionContract.assertInvariants(result, for: input, file: file, line: line)
        return result
    }

    private func single(
        _ result: WorkStateTransitionEngineResult,
        _ kind: WorkStateTransitionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkStateTransitionProposal {
        let matches = result.proposals.filter { $0.transitionKind == kind }
        XCTAssertEqual(matches.count, 1, "expected exactly one \(kind.rawValue) proposal", file: file, line: line)
        return try XCTUnwrap(matches.first, file: file, line: line)
    }

    private func reasons(_ result: WorkStateTransitionEngineResult) -> [WorkStateTransitionReason] {
        result.refusals.map(\.reason)
    }

    // MARK: - 1. No prior state

    func testFirstEverDecisionIsNewAndNeedsNoConfirmation() throws {
        let decisionID = Fixtures.uuid(10)
        let input = Fixtures.input(
            incoming: Fixtures.incoming(decisions: [Fixtures.incomingDecision(id: decisionID)])
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.proposals.count, 1)
        let proposal = try single(result, .new)
        XCTAssertEqual(proposal.workStateKind, .decision)
        XCTAssertNil(proposal.previousStateID)
        XCTAssertEqual(proposal.currentObjectID, decisionID)
        XCTAssertEqual(proposal.basis, .noPriorCandidate)
        XCTAssertFalse(proposal.requiresConfirmation)
        XCTAssertEqual(proposal.reasons, [])
        XCTAssertEqual(proposal.relations, [])
        XCTAssertEqual(
            proposal.evidence,
            TransitionEvidencePointer(
                meetingID: Fixtures.sourceMeetingID,
                transcriptSegmentID: Fixtures.sourceSegmentID
            )
        )
        XCTAssertEqual(proposal.createdAt, Fixtures.generatedAt)
    }

    // MARK: - 2. Restated, unchanged

    func testRestatingAnApprovedDecisionVerbatimIsTheSameDecision() throws {
        let priorID = Fixtures.uuid(20)
        let incomingID = Fixtures.uuid(21)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(decisions: [Fixtures.approvedDecision(id: priorID)]),
            incoming: Fixtures.incoming(decisions: [Fixtures.incomingDecision(id: incomingID)])
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.proposals.count, 1)
        let proposal = try single(result, .same)
        XCTAssertEqual(proposal.workStateKind, .decision)
        XCTAssertEqual(proposal.previousStateID, priorID)
        XCTAssertEqual(proposal.currentObjectID, incomingID)
        XCTAssertEqual(proposal.basis, .exactNormalizedTextMatch)
        // The whole point of `same`: repeating what was already agreed is not a change, so it does
        // not interrupt anyone.
        XCTAssertFalse(proposal.requiresConfirmation)
        XCTAssertEqual(proposal.reasons, [])
    }

    // MARK: - 3. Revised

    func testRevisingAnApprovedDecisionIsChangedAndAlwaysNeedsConfirmation() throws {
        let priorID = Fixtures.uuid(30)
        let incomingID = Fixtures.uuid(31)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                decisions: [Fixtures.approvedDecision(id: priorID, statement: Fixtures.decisionStatement)]
            ),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(id: incomingID, statement: Fixtures.revisedDecisionStatement)
                ]
            )
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.proposals.count, 1)
        let proposal = try single(result, .changed)
        XCTAssertEqual(proposal.previousStateID, priorID)
        XCTAssertEqual(proposal.currentObjectID, incomingID)
        XCTAssertEqual(proposal.basis, .nearTextMatch)
        // Resemblance is a reason to ask, never a reason to act.
        XCTAssertTrue(proposal.requiresConfirmation)
        XCTAssertEqual(proposal.reasons, [.similarityOnly])
    }

    // MARK: - 4. Reported complete

    func testCompletionSignalProducesACompletedProposalAlongsideTheSameProposal() throws {
        let priorID = Fixtures.uuid(40)
        let incomingID = Fixtures.uuid(41)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorID)]),
            incoming: Fixtures.incoming(actionItems: [Fixtures.incomingActionItem(id: incomingID)]),
            progressSignals: [
                WorkStateProgressSignal(
                    kind: .completed,
                    actionItemID: incomingID,
                    evidence: Fixtures.signalEvidence()
                )
            ]
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.proposals.count, 2)

        let completed = try single(result, .completed)
        XCTAssertEqual(completed.workStateKind, .actionItem)
        XCTAssertEqual(completed.previousStateID, priorID)
        XCTAssertEqual(completed.currentObjectID, incomingID)
        XCTAssertEqual(completed.basis, .structuredProgressSignal)
        XCTAssertTrue(completed.requiresConfirmation)
        XCTAssertEqual(completed.reasons, [.stateChangeRequiresApproval])
        // The explanation must be the sentence that claimed completion, not the sentence that
        // restated the task — otherwise the brief cites the wrong line back to the user.
        XCTAssertEqual(
            completed.evidence,
            TransitionEvidencePointer(
                meetingID: Fixtures.sourceMeetingID,
                transcriptSegmentID: Fixtures.signalSegmentID
            )
        )

        let same = try single(result, .same)
        XCTAssertEqual(
            same.evidence,
            TransitionEvidencePointer(
                meetingID: Fixtures.sourceMeetingID,
                transcriptSegmentID: Fixtures.sourceSegmentID
            )
        )
        XCTAssertNotEqual(same.dedupKey, completed.dedupKey)
    }

    // MARK: - 5. Overdue

    func testAnOverdueApprovedActionItemIsDelayedWithoutBeingMentionedAgain() throws {
        let overdueID = Fixtures.uuid(50)
        let undatedID = Fixtures.uuid(51)
        let futureID = Fixtures.uuid(52)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                actionItems: [
                    Fixtures.approvedActionItem(id: overdueID, dueDate: Fixtures.overdueDueDate),
                    Fixtures.approvedActionItem(id: undatedID, title: Fixtures.unrelatedActionItemTitle),
                    Fixtures.approvedActionItem(
                        id: futureID,
                        title: Fixtures.anotherActionItemTitle,
                        dueDate: Fixtures.futureDueDate
                    )
                ]
            )
        )

        let result = generate(input)

        // Lateness is a fact about stored state, so an item nobody mentioned still surfaces —
        // but only the one whose date has actually passed.
        XCTAssertEqual(result.proposals.count, 1)
        let delayed = try single(result, .delayed)
        XCTAssertEqual(delayed.workStateKind, .actionItem)
        XCTAssertEqual(delayed.previousStateID, overdueID)
        XCTAssertNil(delayed.currentObjectID)
        XCTAssertNil(delayed.evidence)
        XCTAssertEqual(delayed.basis, .overdueApprovedDueDate)
        XCTAssertTrue(delayed.requiresConfirmation)
        XCTAssertEqual(delayed.reasons, [.stateChangeRequiresApproval])

        // An undated or not-yet-due task is the ordinary case, not a problem to report.
        XCTAssertEqual(result.refusals, [])
    }

    // MARK: - 6. Explicit deferral

    func testAStructuredDeferralSignalProducesADelayedProposalWithItsOwnEvidence() throws {
        for signalKind in [WorkStateProgressSignalKind.deferred, .blocked] {
            let priorID = Fixtures.uuid(60)
            let incomingID = Fixtures.uuid(61)
            // No due date anywhere, so nothing can be overdue — the delay can only come from the
            // structured signal.
            let input = Fixtures.input(
                prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorID, dueDate: nil)]),
                incoming: Fixtures.incoming(actionItems: [Fixtures.incomingActionItem(id: incomingID)]),
                progressSignals: [
                    WorkStateProgressSignal(
                        kind: signalKind,
                        actionItemID: incomingID,
                        evidence: Fixtures.signalEvidence()
                    )
                ]
            )

            let result = generate(input)

            XCTAssertEqual(result.refusals, [], "\(signalKind.rawValue)")
            let delayed = try single(result, .delayed)
            XCTAssertEqual(delayed.previousStateID, priorID, "\(signalKind.rawValue)")
            XCTAssertEqual(delayed.currentObjectID, incomingID, "\(signalKind.rawValue)")
            XCTAssertEqual(delayed.basis, .structuredProgressSignal, "\(signalKind.rawValue)")
            XCTAssertTrue(delayed.requiresConfirmation, "\(signalKind.rawValue)")
            XCTAssertEqual(delayed.reasons, [.stateChangeRequiresApproval], "\(signalKind.rawValue)")
            XCTAssertEqual(
                delayed.evidence,
                TransitionEvidencePointer(
                    meetingID: Fixtures.sourceMeetingID,
                    transcriptSegmentID: Fixtures.signalSegmentID
                ),
                "\(signalKind.rawValue)"
            )
        }
    }

    // MARK: - 7. Answered by a decision

    func testAnOpenQuestionAnsweredByADecisionIsResolvedAndPointsAtTheDecision() throws {
        let questionID = Fixtures.uuid(70)
        let decisionID = Fixtures.uuid(71)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                openQuestions: [Fixtures.approvedOpenQuestion(id: questionID)]
            ),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(id: decisionID, statement: Fixtures.unrelatedDecisionStatement)
                ]
            ),
            resolutionLinks: [
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: questionID,
                    targetKind: .decision,
                    targetObjectID: decisionID,
                    evidence: Fixtures.linkEvidence()
                )
            ]
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.proposals.count, 2, "the resolution, plus the new decision itself")

        let resolved = try single(result, .resolved)
        XCTAssertEqual(resolved.workStateKind, .openQuestion)
        XCTAssertEqual(resolved.previousStateID, questionID)
        XCTAssertEqual(resolved.currentObjectID, decisionID)
        XCTAssertEqual(resolved.basis, .structuredResolutionLink)
        XCTAssertTrue(resolved.requiresConfirmation)
        XCTAssertEqual(resolved.reasons, [.stateChangeRequiresApproval])
        XCTAssertEqual(
            resolved.relations,
            [
                WorkStateTransitionRelation(
                    kind: .resolvedBy,
                    relatedKind: .decision,
                    relatedObjectID: decisionID
                )
            ]
        )
    }

    // MARK: - 8. Turned into work

    func testAnOpenQuestionTurnedIntoAnActionItemIsResolvedAndPointsAtTheTask() throws {
        let questionID = Fixtures.uuid(80)
        let actionItemID = Fixtures.uuid(81)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                openQuestions: [Fixtures.approvedOpenQuestion(id: questionID)]
            ),
            incoming: Fixtures.incoming(
                actionItems: [Fixtures.incomingActionItem(id: actionItemID)]
            ),
            resolutionLinks: [
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: questionID,
                    targetKind: .actionItem,
                    targetObjectID: actionItemID,
                    evidence: Fixtures.linkEvidence()
                )
            ]
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        let resolved = try single(result, .resolved)
        XCTAssertEqual(resolved.workStateKind, .openQuestion)
        XCTAssertEqual(resolved.previousStateID, questionID)
        XCTAssertEqual(resolved.currentObjectID, actionItemID)
        XCTAssertTrue(resolved.requiresConfirmation)
        XCTAssertEqual(
            resolved.relations,
            [
                WorkStateTransitionRelation(
                    kind: .resolvedBy,
                    relatedKind: .actionItem,
                    relatedObjectID: actionItemID
                )
            ]
        )
        // The task itself is still just a new task; being an answer does not pre-approve it.
        let newTask = try single(result, .new)
        XCTAssertEqual(newTask.workStateKind, .actionItem)
        XCTAssertEqual(newTask.currentObjectID, actionItemID)
    }

    // MARK: - 9. Carried to the next agenda

    func testAnOpenQuestionCarriedToTheAgendaKeepsTheRelationWithoutAnAgendaTransition() throws {
        let questionID = Fixtures.uuid(90)
        let agendaItemID = Fixtures.uuid(91)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                openQuestions: [Fixtures.approvedOpenQuestion(id: questionID)]
            ),
            incoming: Fixtures.incoming(
                agendaItems: [Fixtures.incomingAgendaItem(id: agendaItemID)]
            ),
            resolutionLinks: [
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: questionID,
                    targetKind: .agendaItem,
                    targetObjectID: agendaItemID,
                    evidence: Fixtures.linkEvidence()
                )
            ]
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        let resolved = try single(result, .resolved)
        XCTAssertEqual(resolved.workStateKind, .openQuestion)
        XCTAssertEqual(resolved.previousStateID, questionID)
        XCTAssertEqual(resolved.currentObjectID, agendaItemID)
        // The question left the open list because it now lives on the agenda — a different fact
        // from "someone answered it", and the relation kind is what preserves the difference.
        XCTAssertEqual(
            resolved.relations,
            [
                WorkStateTransitionRelation(
                    kind: .carriedToAgenda,
                    relatedKind: .agendaItem,
                    relatedObjectID: agendaItemID
                )
            ]
        )

        // The agenda row itself may only ever be new or same; carrying a question over must not
        // smuggle a richer agenda transition in through the side door.
        let agendaProposals = result.proposals.filter { $0.workStateKind == .agendaItem }
        XCTAssertEqual(agendaProposals.map(\.transitionKind), [.new])
        for proposal in agendaProposals {
            XCTAssertTrue(
                WorkStateTransitionMatrix.supports(proposal.transitionKind, for: .agendaItem)
            )
        }
    }

    // MARK: - 10. Derived from a decision

    func testADerivedFromLinkIsAttachedToEveryProposalForThatActionItem() throws {
        let decisionID = Fixtures.uuid(100)
        let priorTaskID = Fixtures.uuid(101)
        let incomingTaskID = Fixtures.uuid(102)
        // The task both restates an approved task and is reported complete, so it carries two
        // proposals — the link has to reach both, or the brief can explain one row and not the other.
        let input = Fixtures.input(
            prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorTaskID)]),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(id: decisionID, statement: Fixtures.unrelatedDecisionStatement)
                ],
                actionItems: [Fixtures.incomingActionItem(id: incomingTaskID)]
            ),
            progressSignals: [
                WorkStateProgressSignal(
                    kind: .completed,
                    actionItemID: incomingTaskID,
                    evidence: Fixtures.signalEvidence()
                )
            ],
            derivedActionItemLinks: [
                DecisionDerivedActionItemLink(
                    decisionID: decisionID,
                    actionItemID: incomingTaskID,
                    evidence: Fixtures.linkEvidence()
                )
            ]
        )

        let result = generate(input)

        XCTAssertEqual(result.refusals, [])
        let expectedRelation = WorkStateTransitionRelation(
            kind: .derivedFrom,
            relatedKind: .decision,
            relatedObjectID: decisionID
        )
        let taskProposals = result.proposals.filter { $0.currentObjectID == incomingTaskID }
        XCTAssertEqual(Set(taskProposals.map(\.transitionKind)), [.same, .completed])
        for proposal in taskProposals {
            XCTAssertTrue(
                proposal.relations.contains(expectedRelation),
                "\(proposal.transitionKind.rawValue) lost the derivedFrom relation"
            )
        }

        // A link explains; it never classifies. The decision is still just new, and the task's
        // own transitions are unchanged by the link's presence.
        let newDecision = try single(result, .new)
        XCTAssertEqual(newDecision.currentObjectID, decisionID)
        XCTAssertEqual(newDecision.relations, [])
    }

    // MARK: - 11. Two or more candidates

    func testAmbiguousPriorCandidatesArePreservedIndividuallyAndNeverMerged() throws {
        let exactPriorID = Fixtures.uuid(110)
        let nearPriorID = Fixtures.uuid(111)
        let incomingID = Fixtures.uuid(112)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                decisions: [
                    Fixtures.approvedDecision(id: exactPriorID, statement: Fixtures.decisionStatement),
                    Fixtures.approvedDecision(id: nearPriorID, statement: Fixtures.revisedDecisionStatement)
                ]
            ),
            incoming: Fixtures.incoming(
                decisions: [Fixtures.incomingDecision(id: incomingID, statement: Fixtures.decisionStatement)]
            )
        )

        let result = generate(input)

        // Every candidate survives to the user; nothing is merged away and no winner is pre-picked.
        XCTAssertEqual(result.proposals.count, 2)
        XCTAssertEqual(Set(result.proposals.compactMap(\.previousStateID)), [exactPriorID, nearPriorID])
        XCTAssertEqual(Set(result.proposals.map(\.transitionKind)), [.changed])
        XCTAssertEqual(Set(result.proposals.compactMap(\.currentObjectID)), [incomingID])
        XCTAssertEqual(Set(result.proposals.map(\.dedupKey)).count, 2)

        for proposal in result.proposals {
            XCTAssertTrue(proposal.requiresConfirmation)
            XCTAssertTrue(proposal.reasons.contains(.ambiguousPriorCandidates))
        }

        // Inventing a new item next to unresolved candidates is exactly the duplicate this
        // feature exists to prevent.
        XCTAssertFalse(result.proposals.contains { $0.transitionKind == .new })

        let exact = try XCTUnwrap(result.proposals.first { $0.previousStateID == exactPriorID })
        XCTAssertEqual(exact.basis, .exactNormalizedTextMatch)
        XCTAssertEqual(exact.reasons, [.ambiguousPriorCandidates])

        let near = try XCTUnwrap(result.proposals.first { $0.previousStateID == nearPriorID })
        XCTAssertEqual(near.basis, .nearTextMatch)
        XCTAssertEqual(near.reasons, [.ambiguousPriorCandidates, .similarityOnly])
    }

    // MARK: - 12. A different project

    func testALookAlikeItemInAnotherProjectIsNeverLinked() throws {
        let foreignPriorID = Fixtures.uuid(120)
        let incomingID = Fixtures.uuid(121)

        // A malformed store hands the engine another project's decision with identical text.
        let smuggled = Fixtures.input(
            prior: Fixtures.snapshot(
                decisions: [
                    Fixtures.approvedDecision(
                        id: foreignPriorID,
                        statement: Fixtures.decisionStatement,
                        inProject: Fixtures.otherProjectID
                    )
                ]
            ),
            incoming: Fixtures.incoming(
                decisions: [Fixtures.incomingDecision(id: incomingID, statement: Fixtures.decisionStatement)]
            )
        )

        let result = generate(smuggled)

        let proposal = try single(result, .new)
        XCTAssertNil(proposal.previousStateID, "another project's item must not become a predecessor")
        XCTAssertEqual(proposal.currentObjectID, incomingID)
        XCTAssertEqual(reasons(result), [.crossProjectCandidate])

        // And the mirror image: an incoming object that claims another project is refused outright.
        let foreignIncomingID = Fixtures.uuid(122)
        let foreignIncoming = Fixtures.input(
            prior: Fixtures.snapshot(decisions: [Fixtures.approvedDecision(id: Fixtures.uuid(123))]),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(
                        id: foreignIncomingID,
                        statement: Fixtures.decisionStatement,
                        inProject: Fixtures.otherProjectID
                    )
                ]
            )
        )

        let foreignResult = generate(foreignIncoming)

        XCTAssertEqual(foreignResult.proposals, [])
        XCTAssertEqual(reasons(foreignResult), [.crossProjectCandidate])

        // The snapshot is the first line of defence: it drops the foreign row before the engine
        // ever sees it, so both layers have to fail before a cross-project link becomes possible.
        var project = Fixtures.representativeProject()
        project.decisions = [
            Fixtures.approvedDecision(id: foreignPriorID, inProject: Fixtures.otherProjectID)
        ]
        let snapshot = ApprovedWorkStateSnapshot(project: project)
        XCTAssertEqual(snapshot.projectID, Fixtures.projectID)
        XCTAssertFalse(snapshot.decisions.contains { $0.id == foreignPriorID })
    }

    // MARK: - 13. Missing or mismatched evidence

    func testMissingOrForeignEvidenceIsRefusedInsteadOfSilentlyAccepted() throws {
        let priorID = Fixtures.uuid(130)
        let unevidencedID = Fixtures.uuid(131)
        let misevidencedID = Fixtures.uuid(132)
        // Both incoming decisions restate an approved decision word for word. Without admission
        // they would both be an automatic `same` — which is precisely the silent acceptance the
        // evidence rule exists to stop.
        let input = Fixtures.input(
            prior: Fixtures.snapshot(decisions: [Fixtures.approvedDecision(id: priorID)]),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(id: unevidencedID, evidence: nil),
                    Fixtures.incomingDecision(id: misevidencedID, evidence: Fixtures.foreignEvidence())
                ]
            )
        )

        let result = generate(input)

        XCTAssertEqual(result.proposals, [], "nothing may be classified on evidence that was not checked")
        XCTAssertEqual(
            Set(reasons(result)),
            [.missingEvidence, .evidenceNotInSourceMeeting]
        )
        XCTAssertTrue(result.refusals.allSatisfy { $0.workStateKind == .decision })
        // A refusal has to name the object it refused, or "2 items could not be grounded" is all
        // a caller can ever say about it.
        let referencedObjects = Set(result.refusals.compactMap(\.currentObjectID))
            .union(result.refusals.compactMap(\.previousStateID))
        XCTAssertTrue(referencedObjects.contains(unevidencedID))
        XCTAssertTrue(referencedObjects.contains(misevidencedID))
    }

    // MARK: - 14. Unresolved assignee attribution

    func testAnUnresolvedAssigneeStopsAnythingFromBeingConfirmedAutomatically() throws {
        let priorID = Fixtures.uuid(140)
        let incomingID = Fixtures.uuid(141)

        let unresolved = Fixtures.input(
            prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorID)]),
            incoming: Fixtures.incoming(
                actionItems: [
                    Fixtures.incomingActionItem(id: incomingID, attribution: Fixtures.unresolvedAttribution())
                ]
            )
        )

        let unresolvedResult = generate(unresolved)

        let downgraded = try single(unresolvedResult, .same)
        XCTAssertEqual(downgraded.previousStateID, priorID)
        XCTAssertTrue(downgraded.requiresConfirmation)
        XCTAssertEqual(downgraded.reasons, [.unresolvedAssigneeAttribution])

        // Control: the identical input with a resolved attribution is automatic again, so the
        // downgrade is caused by the resolution and nothing else.
        let resolved = Fixtures.input(
            prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorID)]),
            incoming: Fixtures.incoming(
                actionItems: [
                    Fixtures.incomingActionItem(id: incomingID, attribution: Fixtures.resolvedAttribution())
                ]
            )
        )

        let resolvedResult = generate(resolved)
        let automatic = try single(resolvedResult, .same)
        XCTAssertFalse(automatic.requiresConfirmation)
        XCTAssertEqual(automatic.reasons, [])

        // Attribution only ever downgrades. It must never become a matching signal in its own
        // right: with no textual candidate, an unresolved assignee still links to nothing.
        let unmatched = Fixtures.input(
            prior: Fixtures.snapshot(actionItems: [Fixtures.approvedActionItem(id: priorID)]),
            incoming: Fixtures.incoming(
                actionItems: [
                    Fixtures.incomingActionItem(
                        id: Fixtures.uuid(142),
                        title: Fixtures.unrelatedActionItemTitle,
                        attribution: Fixtures.unresolvedAttribution(.noParticipantMatch)
                    )
                ]
            )
        )

        let unmatchedResult = generate(unmatched)
        let fresh = try single(unmatchedResult, .new)
        XCTAssertNil(fresh.previousStateID)
    }

    // MARK: - 15. Re-running

    func testRunningTheSameInputTwiceProducesIdenticalResults() {
        let input = Fixtures.representativeInput()

        let first = generate(input)
        let second = generate(input)

        XCTAssertEqual(first.proposals, second.proposals)
        XCTAssertEqual(first.refusals, second.refusals)
        XCTAssertEqual(Set(first.proposals.map(\.dedupKey)).count, first.proposals.count)

        // A later clock may only move `createdAt`. Identity has to survive it, or an "app opened
        // the next morning" re-run appends a second copy of every row.
        let later = generate(input, now: Fixtures.generatedAt.addingTimeInterval(86_400))
        XCTAssertEqual(later.proposals.map(\.dedupKey), first.proposals.map(\.dedupKey))
        XCTAssertEqual(later.proposals.map(\.id), first.proposals.map(\.id))
        XCTAssertTrue(later.proposals.allSatisfy { $0.createdAt != Fixtures.generatedAt })
    }

    // MARK: - 16. Restart

    func testRegeneratingAfterARestartAddsNoDuplicates() async throws {
        let url = fileURL("continuity-transitions.json")
        let input = Fixtures.representativeInput()

        let firstRun = generate(input)
        XCTAssertFalse(firstRun.proposals.isEmpty)

        let firstRepository = JSONWorkStateTransitionRepository(fileURL: url)
        try await firstRepository.upsert(firstRun.proposals)

        // A genuinely new instance over the same file stands in for "the app was quit and
        // reopened" — an in-memory cache cannot make this pass.
        let restartedRepository = JSONWorkStateTransitionRepository(fileURL: url)
        let secondRun = generate(input, now: Fixtures.generatedAt.addingTimeInterval(3_600))
        try await restartedRepository.upsert(secondRun.proposals)

        let stored = try await restartedRepository.proposals(forProject: Fixtures.projectID)
        XCTAssertEqual(stored.count, firstRun.proposals.count)
        XCTAssertEqual(Set(stored.map(\.dedupKey)), Set(firstRun.proposals.map(\.dedupKey)))
        XCTAssertEqual(Set(stored.map(\.id)).count, stored.count)
        XCTAssertEqual(stored.map(\.dedupKey), stored.map(\.dedupKey).sorted())

        // A third instance confirms the file itself, not one actor's state, holds the truth.
        let reopenedRepository = JSONWorkStateTransitionRepository(fileURL: url)
        let all = try await reopenedRepository.allProposals()
        XCTAssertEqual(all.count, firstRun.proposals.count)
    }

    // MARK: - 17. Reloading an existing store

    func testLoadingAStoreFileWrittenEarlierLosesNothing() async throws {
        let url = fileURL("continuity-transitions.json")
        let input = Fixtures.representativeInput()
        let generated = generate(input)

        let writer = JSONWorkStateTransitionRepository(fileURL: url)
        try await writer.upsert(generated.proposals)

        let reader = JSONWorkStateTransitionRepository(fileURL: url)
        let loaded = try await reader.allProposals()

        // Full value equality: reasons, relations, evidence pointer, basis and timestamps all have
        // to come back, because each of them is something the brief will later have to show.
        XCTAssertEqual(loaded, generated.proposals.sorted { $0.dedupKey < $1.dedupKey })

        let decoded = try JSONDecoder().decode(WorkStateTransitionStoreFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.schemaVersion, WorkStateTransitionStoreFile.currentSchemaVersion)
        XCTAssertEqual(decoded.proposals.count, generated.proposals.count)
    }

    // MARK: - 18. Unsupported combinations

    func testAnUnsupportedTransitionForAKindIsRefusedExplicitly() throws {
        let priorAgendaID = Fixtures.uuid(180)
        let incomingAgendaID = Fixtures.uuid(181)
        let input = Fixtures.input(
            prior: Fixtures.snapshot(
                agendaItems: [Fixtures.approvedAgendaItem(id: priorAgendaID, title: Fixtures.agendaTitle)]
            ),
            incoming: Fixtures.incoming(
                agendaItems: [
                    Fixtures.incomingAgendaItem(id: incomingAgendaID, title: Fixtures.revisedAgendaTitle)
                ]
            )
        )

        let result = generate(input)

        // An agenda line is free text a person may have typed, so "this is a revision of that one"
        // is a claim v0 refuses to make rather than guesses at.
        XCTAssertEqual(result.proposals, [])
        XCTAssertTrue(
            result.refusals.contains {
                $0.workStateKind == .agendaItem && $0.reason == .unsupportedTransitionForKind
            },
            "the refusal must say why, not just produce nothing"
        )

        XCTAssertEqual(WorkStateTransitionMatrix.supportedTransitions(for: .agendaItem), [.new, .same])
        XCTAssertEqual(WorkStateTransitionMatrix.supportedTransitions(for: .decision), [.new, .same, .changed])
        XCTAssertEqual(
            WorkStateTransitionMatrix.supportedTransitions(for: .actionItem),
            [.new, .same, .changed, .completed, .delayed]
        )
        XCTAssertEqual(
            WorkStateTransitionMatrix.supportedTransitions(for: .openQuestion),
            [.new, .same, .changed, .resolved]
        )
        XCTAssertFalse(WorkStateTransitionMatrix.supports(.completed, for: .decision))
        XCTAssertFalse(WorkStateTransitionMatrix.supports(.resolved, for: .actionItem))
        XCTAssertFalse(WorkStateTransitionMatrix.supports(.changed, for: .agendaItem))
    }

    // MARK: - 19. Approved state is read-only

    func testGeneratingProposalsNeitherMutatesTheProjectNorOpensItsFile() async throws {
        let projectsURL = fileURL("projects.json")
        let transitionsURL = fileURL("continuity-transitions.json")

        let project = Fixtures.representativeProject()
        let projectRepository = JSONProjectRepository(fileURL: projectsURL)
        try await projectRepository.save(project)
        let projectsBytesBefore = try Data(contentsOf: projectsURL)

        let input = WorkStateTransitionEngineInput(
            projectID: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            occurredAt: Fixtures.occurredAt,
            prior: ApprovedWorkStateSnapshot(project: project),
            incoming: Fixtures.representativeInput().incoming,
            progressSignals: [],
            resolutionLinks: [],
            derivedActionItemLinks: []
        )
        let result = generate(input)
        XCTAssertFalse(result.proposals.isEmpty)

        let transitionRepository = JSONWorkStateTransitionRepository(fileURL: transitionsURL)
        try await transitionRepository.upsert(result.proposals)

        // The value the caller passed in is untouched...
        XCTAssertEqual(project, Fixtures.representativeProject())
        // ...and so is the file that holds approved work state. This is the structural guarantee:
        // the feature writes to its own file and never opens `projects.json` at all.
        XCTAssertEqual(try Data(contentsOf: projectsURL), projectsBytesBefore)
        let reloaded = try await JSONProjectRepository(fileURL: projectsURL).project(id: project.id)
        XCTAssertEqual(reloaded, project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: transitionsURL.path))
        XCTAssertNotEqual(transitionsURL, projectsURL)
        XCTAssertEqual(
            JSONWorkStateTransitionRepository.defaultFileURL().lastPathComponent,
            "continuity-transitions.json"
        )
        XCTAssertNotEqual(
            JSONWorkStateTransitionRepository.defaultFileURL(),
            JSONProjectRepository.defaultFileURL()
        )
    }

    // MARK: - 20. A failed write

    private struct TransitionStoreUnavailable: Error {}

    func testAFailedRepositoryWriteLeavesApprovedStateIntactAndIsNotReportedAsSuccess() async throws {
        let project = Fixtures.representativeProject()
        let input = Fixtures.representativeInput()
        let result = generate(input)
        XCTAssertFalse(result.proposals.isEmpty)

        let repository = InMemoryWorkStateTransitionRepository(saveError: TransitionStoreUnavailable())

        do {
            try await repository.upsert(result.proposals)
            XCTFail("a failed write must surface as a thrown error, never as a silent no-op")
        } catch is TransitionStoreUnavailable {
            // expected
        }

        // Nothing was stored, so nothing can later be mistaken for an accepted transition.
        let stored = (try? await repository.allProposals()) ?? []
        XCTAssertEqual(stored, [])

        // The approved work state never depended on the write succeeding, and the generated rows
        // are still unreviewed proposals rather than applied changes.
        XCTAssertEqual(project, Fixtures.representativeProject())
        XCTAssertTrue(result.proposals.allSatisfy { $0.reviewStatus == .pendingReview })
    }
}
