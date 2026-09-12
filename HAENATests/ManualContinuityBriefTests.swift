import XCTest
@testable import HAENA

final class ManualContinuityBriefTests: XCTestCase {
    private enum TestFailure: Error { case unavailable }

    // MARK: - Confirmed state and personalisation (1-4)

    func testScenario1ApprovedDecisionAppearsInConfirmedDecisions() async throws {
        var project = project()
        project.decisions = [decision(1, status: .confirmed)]

        let brief = try await load(project: project)

        XCTAssertEqual(brief.confirmedDecisions, project.decisions)
    }

    func testScenario2PendingDecisionNeverAppearsInConfirmedDecisions() async throws {
        var project = project()
        project.decisions = [decision(1, status: .confirmed), decision(2, status: .proposed)]

        let brief = try await load(project: project)

        XCTAssertEqual(brief.confirmedDecisions.map(\.id), [id(1)])
    }

    func testScenario3IdentifiedProfileSplitsMineThroughMyWorkPolicy() async throws {
        var project = project()
        project.actionItems = [action(1, assigneeID: id(101)), action(2, assigneeID: id(102))]
        let profile = LocalUserProfile(displayName: "사용자", linkedParticipantIDs: [id(101)])

        let brief = try await load(project: project, profile: profile)

        XCTAssertEqual(brief.personalisation, .personalised)
        XCTAssertEqual(brief.myActiveCommitments.map(\.id), [id(1)])
        XCTAssertEqual(brief.otherCommitments.map(\.id), [id(2)])
    }

    func testScenario4MissingProfileNeverClaimsWorkIsMine() async throws {
        var project = project()
        project.actionItems = [action(1, assigneeID: id(101)), action(2, assigneeID: nil)]

        let brief = try await load(project: project, profile: nil)

        XCTAssertEqual(brief.personalisation, .notConfigured)
        XCTAssertTrue(brief.myActiveCommitments.isEmpty)
        XCTAssertEqual(Set(brief.otherCommitments.map(\.id)), [id(1), id(2)])
    }

    func testCompletedUserWorkIsSeparateFromActiveAndExcludesCancelledOrProposed() async throws {
        var project = project()
        var completed = action(1)
        completed.status = .completed
        var cancelled = action(2)
        cancelled.status = .cancelled
        var proposed = action(3, evidence: reference())
        proposed.status = .proposed
        project.actionItems = [proposed, cancelled, completed, action(4)]

        let brief = try await load(project: project)

        XCTAssertEqual(brief.completedCommitments.map(\.id), [id(1)])
        XCTAssertEqual(brief.otherCommitments.map(\.id), [id(4)])
        XCTAssertFalse(brief.agendaCandidates.contains { $0.agendaItem.id == completed.id })
    }

    // MARK: - Typed transition candidates (5-13)

    func testScenario5StructuredDeferredRemainsDistinct() async throws {
        var project = project()
        project.actionItems = [action(1)]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            currentID: id(1),
            evidence: pointer(),
            basis: .structuredProgressSignal,
            disposition: .deferred
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.delayedOrBlockedItems.map(\.kind), [.deferred])
    }

    func testScenario6StructuredBlockedRemainsDistinct() async throws {
        var project = project()
        project.actionItems = [action(1)]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            currentID: id(1),
            evidence: pointer(),
            basis: .structuredProgressSignal,
            disposition: .blocked
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.delayedOrBlockedItems.map(\.kind), [.blocked])
    }

    func testScenario7OverdueRemainsDistinctFromStructuredDelay() async throws {
        var project = project()
        project.actionItems = [action(1, dueDate: Self.date.addingTimeInterval(-100))]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            basis: .overdueApprovedDueDate
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.delayedOrBlockedItems.map(\.kind), [.overdue])
    }

    func testScenario8UndatedTaskDoesNotBecomeOverdueWithoutTypedTransition() async throws {
        var project = project()
        project.actionItems = [action(1, dueDate: nil)]

        let brief = try await load(project: project)

        XCTAssertTrue(brief.delayedOrBlockedItems.isEmpty)
        XCTAssertEqual(brief.otherCommitments.map(\.id), [id(1)])
    }

    func testScenario9CompletedProposalIsPreservedAsPendingCandidate() async throws {
        var project = project()
        project.actionItems = [action(1)]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .completed,
            previousID: id(1),
            currentID: id(1),
            evidence: pointer(),
            basis: .structuredProgressSignal
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions.map(\.proposal), [row])
        XCTAssertEqual(brief.pendingTransitions[0].destructiveApplyState, .enabled)
    }

    func testScenario10OpenQuestionResolutionIsPreservedAsPendingCandidate() async throws {
        var project = project()
        project.openQuestions = [question(1)]
        project.decisions = [decision(2, status: .proposed)]
        let relation = WorkStateTransitionRelation(
            kind: .resolvedBy,
            relatedKind: .decision,
            relatedObjectID: id(2)
        )
        let row = proposal(
            1,
            kind: .openQuestion,
            transition: .resolved,
            previousID: id(1),
            currentID: id(2),
            evidence: pointer(),
            basis: .structuredResolutionLink,
            relations: [relation]
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].proposal.relations, [relation])
        XCTAssertEqual(brief.pendingTransitions[0].currentState, .decision(project.decisions[0]))
    }

    func testScenario11CarriedToAgendaRelationCreatesAgendaCandidate() async throws {
        var project = project()
        project.openQuestions = [question(1)]
        project.nextAgenda = [agenda(2, reviewedAt: nil)]
        let relation = WorkStateTransitionRelation(
            kind: .carriedToAgenda,
            relatedKind: .agendaItem,
            relatedObjectID: id(2)
        )
        let row = proposal(
            1,
            kind: .openQuestion,
            transition: .resolved,
            previousID: id(1),
            currentID: id(2),
            evidence: pointer(),
            basis: .structuredResolutionLink,
            relations: [relation]
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.agendaCandidates.map(\.agendaItem.id), [id(2)])
        XCTAssertEqual(
            brief.agendaCandidates[0].sources.map(\.kind),
            [.carriedToAgenda, .pendingAgendaItem]
        )
    }

    func testScenario12DerivedFromRelationIsNotFlattenedAway() async throws {
        var project = project()
        project.decisions = [decision(1, status: .confirmed)]
        project.actionItems = [action(2)]
        let relation = WorkStateTransitionRelation(
            kind: .derivedFrom,
            relatedKind: .decision,
            relatedObjectID: id(1)
        )
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .completed,
            previousID: id(2),
            currentID: id(2),
            evidence: pointer(),
            basis: .structuredProgressSignal,
            relations: [relation]
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].proposal.relations, [relation])
    }

    func testScenario13UnresolvedQuestionAloneDoesNotInventAgendaCandidate() async throws {
        var project = project()
        project.openQuestions = [question(1)]
        project.nextAgenda = []

        let brief = try await load(project: project)

        XCTAssertEqual(brief.unresolvedQuestions.map(\.id), [id(1)])
        XCTAssertTrue(brief.agendaCandidates.isEmpty)
    }

    func testPendingNewWithResolvedCurrentEvidenceCanBeApproved() async throws {
        var project = project()
        project.decisions = [decision(1, status: .proposed)]
        let missingPointer = TransitionEvidencePointer(
            meetingID: Self.meetingID,
            transcriptSegmentID: id(999)
        )
        let row = proposal(
            1,
            kind: .decision,
            transition: .new,
            currentID: id(1),
            evidence: missingPointer,
            basis: .noPriorCandidate
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].destructiveApplyState, .enabled)
        XCTAssertEqual(brief.pendingTransitions[0].sourceMeetingTitle, "회의")
        XCTAssertEqual(
            brief.pendingTransitions[0].evidence,
            .resolved(
                ManualContinuityBriefEvidenceSegment(
                    meetingID: Self.meetingID,
                    meetingTitle: "회의",
                    transcriptSegmentID: Self.segmentID,
                    text: "근거 문장"
                )
            )
        )
    }

    func testCurrentWorkStateEvidenceTakesPrecedenceEvenWhenDangling() async throws {
        var project = project()
        var current = decision(1, status: .proposed)
        current.evidence = EvidenceReference(
            meetingID: Self.meetingID,
            transcriptSegmentID: Self.segmentID,
            quote: "존재하지 않는 인용"
        )
        project.decisions = [current]
        let row = proposal(
            1,
            kind: .decision,
            transition: .new,
            currentID: id(1),
            evidence: pointer(),
            basis: .noPriorCandidate
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].evidence, .dangling(.quoteNotInSegment))
        XCTAssertEqual(
            brief.pendingTransitions[0].destructiveApplyState,
            .disabled(.danglingEvidence)
        )
    }

    func testDelayPriorityIsBlockedThenOverdueThenDeferred() async throws {
        var project = project()
        project.actionItems = [action(1), action(2), action(3)]
        let rows = [
            proposal(1, kind: .actionItem, transition: .delayed, previousID: id(1), currentID: id(1), evidence: pointer(), basis: .structuredProgressSignal, disposition: .deferred),
            proposal(2, kind: .actionItem, transition: .delayed, previousID: id(2), basis: .overdueApprovedDueDate),
            proposal(3, kind: .actionItem, transition: .delayed, previousID: id(3), currentID: id(3), evidence: pointer(), basis: .structuredProgressSignal, disposition: .blocked)
        ]

        let brief = try await load(project: project, proposals: rows)

        XCTAssertEqual(brief.delayedOrBlockedItems.map(\.kind), [.blocked, .overdue, .deferred])
    }

    func testDelayAssigneeDisplayIsResolvedLocallyAndUnknownIDStaysNil() async throws {
        var project = project()
        project.meetings[0].participants = [
            Participant(id: id(101), displayName: "담당자", linkedUserID: nil, speakerLabel: nil)
        ]
        project.actionItems = [
            action(1, assigneeID: id(101)),
            action(2, assigneeID: id(999))
        ]
        let rows = [
            proposal(1, kind: .actionItem, transition: .delayed, previousID: id(1), currentID: id(1), evidence: pointer(), basis: .structuredProgressSignal, disposition: .blocked),
            proposal(2, kind: .actionItem, transition: .delayed, previousID: id(2), currentID: id(2), evidence: pointer(), basis: .structuredProgressSignal, disposition: .deferred)
        ]

        let brief = try await load(project: project, proposals: rows)
        let namesByActionID = Dictionary(uniqueKeysWithValues: brief.delayedOrBlockedItems.compactMap { delay in
            delay.actionItem.map { ($0.id, delay.assigneeDisplayName) }
        })

        XCTAssertEqual(namesByActionID[id(1)]!, "담당자")
        XCTAssertNil(namesByActionID[id(2)]!)
    }

    func testReviewedAmbiguityDoesNotReappearAsUnresolved() async throws {
        var project = project()
        project.decisions = [decision(1, status: .confirmed), decision(2, status: .proposed)]
        let group = WorkStateAmbiguousMatchGroup(
            projectID: Self.projectID,
            sourceMeetingID: Self.meetingID,
            workStateKind: .decision,
            incomingObjectID: id(2),
            priorCandidateIDs: [id(1)]
        )
        let review = WorkStateAmbiguityReviewState(
            groupID: group.id,
            projectID: Self.projectID,
            selectionKind: .priorCandidate,
            selectedPriorStateID: id(1),
            reviewedAt: Self.date
        )

        let brief = try await load(project: project, groups: [group], ambiguityReviews: [review])

        XCTAssertTrue(brief.ambiguousMatches.isEmpty)
    }

    func testOnlyUnreviewedAgendaIsCandidateAndCarriesItsReviewTransitionID() async throws {
        var project = project()
        project.nextAgenda = [agenda(1, reviewedAt: nil), agenda(2, reviewedAt: Self.date)]
        project.openQuestions = [question(3)]
        let pendingRow = proposal(
            1,
            kind: .agendaItem,
            transition: .new,
            currentID: id(1),
            evidence: pointer(),
            basis: .noPriorCandidate
        )
        let staleReviewedRow = proposal(
            2,
            kind: .agendaItem,
            transition: .new,
            currentID: id(2),
            evidence: pointer(),
            basis: .noPriorCandidate
        )
        let reviewedAgendaCarry = proposal(
            3,
            kind: .openQuestion,
            transition: .resolved,
            previousID: id(3),
            currentID: id(2),
            evidence: pointer(),
            basis: .structuredResolutionLink,
            relations: [
                WorkStateTransitionRelation(
                    kind: .carriedToAgenda,
                    relatedKind: .agendaItem,
                    relatedObjectID: id(2)
                )
            ]
        )

        let brief = try await load(
            project: project,
            proposals: [reviewedAgendaCarry, staleReviewedRow, pendingRow]
        )

        XCTAssertEqual(brief.agendaCandidates.map(\.agendaItem.id), [id(1)])
        XCTAssertEqual(brief.agendaCandidates[0].sources.first?.transitionID, pendingRow.id)
        XCTAssertEqual(brief.agendaCandidates[0].sources.first?.destructiveApplyState, .enabled)
        XCTAssertEqual(brief.approvedNextAgenda.map(\.id), [id(2)])
    }

    /// The Brief and the AI 제안 inbox must answer "is this agenda item still waiting on me?" the
    /// same way, and the Project is the only thing either is allowed to answer it from.
    ///
    /// Both halves regressed in opposite directions on real data. A terminal transition verdict
    /// used to hide a Project-pending item from the Brief while the inbox kept offering it; and a
    /// Project verdict had to reach the Brief even while the item's own `new` transition sat
    /// unreviewed, because nothing ever writes that row when the verdict comes from the inbox.
    func testAgendaCandidacyFollowsProjectVerdictAndAgreesWithTheInbox() async throws {
        let ownTransition = { (index: Int) in
            self.proposal(
                index,
                kind: .agendaItem,
                transition: .new,
                currentID: self.id(index),
                evidence: self.pointer(),
                basis: .noPriorCandidate
            )
        }

        var dismissed = project()
        dismissed.nextAgenda = [agenda(1, reviewedAt: Self.date, status: .dismissed)]
        let afterDismissal = try await load(project: dismissed, proposals: [ownTransition(1)])
        XCTAssertTrue(
            afterDismissal.agendaCandidates.isEmpty,
            "a dismissed agenda item is decided, whichever screen decided it"
        )
        XCTAssertTrue(afterDismissal.approvedNextAgenda.isEmpty)
        XCTAssertTrue(
            WorkStateInbox.pendingProposals(in: dismissed).isEmpty,
            "the inbox must not re-offer what the Brief dismissed"
        )

        var approved = project()
        approved.nextAgenda = [agenda(2, reviewedAt: Self.date)]
        let afterApproval = try await load(project: approved, proposals: [ownTransition(2)])
        XCTAssertTrue(afterApproval.agendaCandidates.isEmpty)
        XCTAssertEqual(afterApproval.approvedNextAgenda.map(\.id), [id(2)])
        XCTAssertTrue(WorkStateInbox.pendingProposals(in: approved).isEmpty)

        // Legacy shape: the sidecar went terminal but the Project never did. Neither screen may
        // treat that as a verdict — both show it again so a person can decide once.
        var legacy = project()
        legacy.nextAgenda = [agenda(3, reviewedAt: nil)]
        let rejectedSidecar = proposal(
            3,
            kind: .agendaItem,
            transition: .new,
            currentID: id(3),
            evidence: pointer(),
            basis: .noPriorCandidate,
            review: .rejected
        )
        let afterLegacy = try await load(project: legacy, proposals: [rejectedSidecar])
        XCTAssertEqual(
            afterLegacy.agendaCandidates.map(\.agendaItem.id),
            [id(3)],
            "a terminal sidecar is not a user verdict on the agenda item"
        )
        XCTAssertEqual(
            WorkStateInbox.pendingProposals(in: legacy).compactMap {
                if case .agendaItem(let item) = $0 { return item.id } else { return nil }
            },
            [id(3)]
        )
    }

    func testAmbiguitySelectionsExposeEvidenceAndSiblingTransitionForEveryChoice() async throws {
        var project = project()
        project.decisions = [decision(1, status: .confirmed), decision(2, status: .proposed)]
        let group = WorkStateAmbiguousMatchGroup(
            projectID: Self.projectID,
            sourceMeetingID: Self.meetingID,
            workStateKind: .decision,
            incomingObjectID: id(2),
            priorCandidateIDs: [id(1)]
        )
        let sibling = proposal(
            1,
            kind: .decision,
            transition: .changed,
            previousID: id(1),
            currentID: id(2),
            evidence: pointer(),
            basis: .nearTextMatch
        )

        let brief = try await load(project: project, proposals: [sibling], groups: [group])
        let selections = brief.ambiguousMatches[0].selections

        XCTAssertEqual(selections.map(\.selection), [.priorCandidate(id(1)), .new])
        XCTAssertEqual(selections[0].transitionID, sibling.id)
        XCTAssertEqual(selections[0].destructiveApplyState, .enabled)
        XCTAssertEqual(selections[1].transitionID, nil)
        XCTAssertEqual(selections[1].destructiveApplyState, .enabled)
        XCTAssertTrue(selections.allSatisfy {
            if case .resolved = $0.evidence { return true }
            return false
        })
    }

    func testDanglingIncomingEvidenceDisablesEveryAmbiguitySelection() async throws {
        var project = project()
        var incoming = decision(2, status: .proposed)
        incoming.evidence = EvidenceReference(
            meetingID: Self.meetingID,
            transcriptSegmentID: Self.segmentID,
            quote: "삭제된 인용"
        )
        project.decisions = [decision(1, status: .confirmed), incoming]
        let group = WorkStateAmbiguousMatchGroup(
            projectID: Self.projectID,
            sourceMeetingID: Self.meetingID,
            workStateKind: .decision,
            incomingObjectID: id(2),
            priorCandidateIDs: [id(1)]
        )
        let sibling = proposal(
            1,
            kind: .decision,
            transition: .changed,
            previousID: id(1),
            currentID: id(2),
            evidence: pointer(),
            basis: .nearTextMatch
        )

        let brief = try await load(project: project, proposals: [sibling], groups: [group])

        XCTAssertEqual(
            brief.ambiguousMatches[0].selections.map(\.evidence),
            [.dangling(.quoteNotInSegment), .dangling(.quoteNotInSegment)]
        )
        XCTAssertEqual(
            brief.ambiguousMatches[0].selections.map(\.destructiveApplyState),
            [.disabled(.danglingEvidence), .disabled(.danglingEvidence)]
        )
    }

    // MARK: - Evidence safety (25-27)

    func testScenario25DeletedEvidenceSegmentDisablesDestructiveApply() async throws {
        var project = project()
        project.actionItems = [action(1)]
        project.meetings[0].transcriptSegments = []
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .completed,
            previousID: id(1),
            currentID: id(1),
            evidence: pointer(),
            basis: .structuredProgressSignal
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].evidence, .dangling(.missingSegment))
        XCTAssertEqual(
            brief.pendingTransitions[0].destructiveApplyState,
            .disabled(.danglingEvidence)
        )
    }

    func testScenario26UserEnteredPriorWithoutEvidenceIsNormalWhenCurrentEvidenceResolves() async throws {
        var project = project()
        project.actionItems = [action(1, evidence: nil)]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .completed,
            previousID: id(1),
            currentID: id(1),
            evidence: pointer(),
            basis: .structuredProgressSignal
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].previousState, .actionItem(project.actionItems[0]))
        XCTAssertEqual(brief.pendingTransitions[0].destructiveApplyState, .enabled)
        XCTAssertFalse(brief.warnings.contains { $0.kind == .missingRequiredEvidence })
    }

    func testScenario27OverdueCanBeReviewedWithoutTranscriptEvidence() async throws {
        var project = project()
        project.actionItems = [action(1, evidence: nil, dueDate: Self.date.addingTimeInterval(-100))]
        let row = proposal(
            1,
            kind: .actionItem,
            transition: .delayed,
            previousID: id(1),
            basis: .overdueApprovedDueDate
        )

        let brief = try await load(project: project, proposals: [row])

        XCTAssertEqual(brief.pendingTransitions[0].evidence, .notRequired)
        XCTAssertEqual(brief.pendingTransitions[0].destructiveApplyState, .enabled)
    }

    // MARK: - Availability, isolation, determinism (34-36)

    func testScenario34TransitionUnavailableIsDistinctFromAvailableEmpty() async throws {
        let available = try await load(project: project())
        let unavailable = try await load(project: project(), transitionReadFails: true)

        XCTAssertEqual(available.transitionAvailability, .available)
        XCTAssertEqual(available.pendingTransitions, [])
        XCTAssertEqual(unavailable.transitionAvailability, .unavailable)
        XCTAssertEqual(unavailable.pendingTransitions, [])
        XCTAssertTrue(unavailable.warnings.contains { $0.kind == .transitionsUnavailable })
    }

    func testScenario35LoadingBriefPerformsNoRepositoryMutation() async throws {
        let projectRepository = CountingProjectRepository(project: project())
        let transitionRepository = CountingTransitionRepository()
        let profileRepository = CountingProfileRepository(profile: nil)
        let service = ManualContinuityBriefService(
            projects: projectRepository,
            transitions: transitionRepository,
            profiles: profileRepository
        )

        _ = await service.load(projectID: Self.projectID)

        let projectReads = await projectRepository.readCount
        let projectWrites = await projectRepository.writeCount
        let proposalReads = await transitionRepository.projectProposalReadCount
        let ambiguityReads = await transitionRepository.projectAmbiguityReadCount
        let transitionWrites = await transitionRepository.writeCount
        let profileReads = await profileRepository.readCount
        let profileWrites = await profileRepository.writeCount
        XCTAssertEqual(projectReads, 1)
        XCTAssertEqual(projectWrites, 0)
        XCTAssertEqual(proposalReads, 1)
        XCTAssertEqual(ambiguityReads, 1)
        XCTAssertEqual(transitionWrites, 0)
        XCTAssertEqual(profileReads, 1)
        XCTAssertEqual(profileWrites, 0)
    }

    func testScenario36SameInputHasStableTotalOrderAndPreservesEveryItem() async throws {
        var source = project()
        source.decisions = [decision(3, status: .confirmed), decision(1, status: .confirmed), decision(2, status: .confirmed)]
        source.actionItems = [action(6), action(4), action(5)]
        source.openQuestions = [question(9), question(7), question(8)]
        source.nextAgenda = [agenda(12, reviewedAt: Self.date), agenda(10, reviewedAt: Self.date), agenda(11, reviewedAt: Self.date)]
        let rows = [
            proposal(3, kind: .decision, transition: .changed, previousID: id(3), currentID: id(3), evidence: pointer(), basis: .nearTextMatch),
            proposal(1, kind: .actionItem, transition: .completed, previousID: id(4), currentID: id(4), evidence: pointer(), basis: .structuredProgressSignal),
            proposal(2, kind: .openQuestion, transition: .changed, previousID: id(7), currentID: id(7), evidence: pointer(), basis: .nearTextMatch)
        ]

        let first = try await load(project: source, proposals: rows)
        source.decisions.reverse()
        source.actionItems.reverse()
        source.openQuestions.reverse()
        source.nextAgenda.reverse()
        let second = try await load(project: source, proposals: Array(rows.reversed()))

        XCTAssertEqual(first.confirmedDecisions, second.confirmedDecisions)
        XCTAssertEqual(first.otherCommitments, second.otherCommitments)
        XCTAssertEqual(first.unresolvedQuestions, second.unresolvedQuestions)
        XCTAssertEqual(first.approvedNextAgenda, second.approvedNextAgenda)
        XCTAssertEqual(first.pendingTransitions, second.pendingTransitions)
        XCTAssertEqual(first.confirmedDecisions.count, 3)
        XCTAssertEqual(first.otherCommitments.count, 3)
        XCTAssertEqual(first.unresolvedQuestions.count, 3)
        XCTAssertEqual(first.approvedNextAgenda.count, 3)
        XCTAssertEqual(first.pendingTransitions.count, 3)
    }

    // MARK: - Helpers

    private func load(
        project: Project,
        proposals: [WorkStateTransitionProposal] = [],
        groups: [WorkStateAmbiguousMatchGroup] = [],
        ambiguityReviews: [WorkStateAmbiguityReviewState] = [],
        profile: LocalUserProfile? = nil,
        transitionReadFails: Bool = false
    ) async throws -> ManualContinuityBrief {
        let result = await ManualContinuityBriefService(
            projects: CountingProjectRepository(project: project),
            transitions: CountingTransitionRepository(
                proposals: proposals,
                groups: groups,
                ambiguityReviews: ambiguityReviews,
                readFails: transitionReadFails
            ),
            profiles: CountingProfileRepository(profile: profile)
        ).load(projectID: project.id)
        guard case .loaded(let brief) = result else {
            XCTFail("expected loaded brief, got \(result)")
            throw TestFailure.unavailable
        }
        return brief
    }

    private static let projectID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private static let meetingID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
    private static let segmentID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000003")!
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "BBBBBBBB-0000-4000-8000-%012d", number))!
    }

    private func project() -> Project {
        Project(
            id: Self.projectID,
            name: "프로젝트",
            summary: "",
            createdAt: Self.date,
            updatedAt: Self.date,
            meetings: [
                Meeting(
                    id: Self.meetingID,
                    projectID: Self.projectID,
                    title: "회의",
                    occurredAt: Self.date,
                    sourceType: .pastedText,
                    participants: [],
                    transcriptSegments: [
                        TranscriptSegment(
                            id: Self.segmentID,
                            meetingID: Self.meetingID,
                            speakerID: nil,
                            text: "근거 문장",
                            startTime: nil,
                            endTime: nil
                        )
                    ],
                    createdAt: Self.date
                )
            ],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    private func decision(_ number: Int, status: DecisionStatus) -> Decision {
        Decision(
            id: id(number),
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            statement: "결정 \(number)",
            rationale: nil,
            status: status,
            evidence: status == .proposed ? reference() : nil,
            confidence: Confidence(1),
            createdAt: Self.date,
            updatedAt: Self.date
        )
    }

    private func action(
        _ number: Int,
        assigneeID: UUID? = nil,
        evidence: EvidenceReference? = nil,
        dueDate: Date? = nil
    ) -> ActionItem {
        ActionItem(
            id: id(number),
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            title: "업무 \(number)",
            details: nil,
            assigneeID: assigneeID,
            dueDate: dueDate,
            status: .confirmed,
            evidence: evidence,
            confidence: Confidence(1),
            createdAt: Self.date,
            updatedAt: Self.date
        )
    }

    private func question(_ number: Int) -> OpenQuestion {
        OpenQuestion(
            id: id(number),
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            question: "질문 \(number)",
            status: .open,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: Self.date,
            resolvedAt: nil,
            reviewedAt: Self.date
        )
    }

    private func agenda(
        _ number: Int,
        reviewedAt: Date?,
        status: AgendaItemStatus = .pending
    ) -> AgendaItem {
        AgendaItem(
            id: id(number),
            projectID: Self.projectID,
            title: "안건 \(number)",
            reason: "이유",
            sourceMeetingID: Self.meetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: status,
            createdAt: Self.date,
            evidence: reviewedAt == nil ? reference() : nil,
            confidence: reviewedAt == nil ? Confidence(1) : nil,
            reviewedAt: reviewedAt
        )
    }

    private func reference() -> EvidenceReference {
        EvidenceReference(
            meetingID: Self.meetingID,
            transcriptSegmentID: Self.segmentID,
            quote: "근거 문장"
        )
    }

    private func pointer() -> TransitionEvidencePointer {
        TransitionEvidencePointer(meetingID: Self.meetingID, transcriptSegmentID: Self.segmentID)
    }

    private func proposal(
        _ number: Int,
        kind: WorkStateKind,
        transition: WorkStateTransitionKind,
        previousID: UUID? = nil,
        currentID: UUID? = nil,
        evidence: TransitionEvidencePointer? = nil,
        basis: WorkStateTransitionBasis,
        disposition: WorkStateTransitionProgressDisposition? = nil,
        review: WorkStateTransitionReviewStatus = .pendingReview,
        relations: [WorkStateTransitionRelation] = []
    ) -> WorkStateTransitionProposal {
        let key = "manual-brief-\(number)"
        return WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
            projectID: Self.projectID,
            workStateKind: kind,
            transitionKind: transition,
            previousStateID: previousID,
            currentObjectID: currentID,
            sourceMeetingID: Self.meetingID,
            evidence: evidence,
            basis: basis,
            progressDisposition: disposition,
            reasons: transition == .new || transition == .same ? [] : [.stateChangeRequiresApproval],
            requiresConfirmation: transition != .new && transition != .same,
            reviewStatus: review,
            relations: relations,
            dedupKey: key,
            createdAt: Self.date
        )
    }
}

private actor CountingProjectRepository: ProjectRepository {
    let storedProject: Project?
    let readFails: Bool
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(project: Project?, readFails: Bool = false) {
        storedProject = project
        self.readFails = readFails
    }

    func project(id: UUID) throws -> Project? {
        readCount += 1
        if readFails { throw ManualBriefTestRepositoryError.unavailable }
        return storedProject?.id == id ? storedProject : nil
    }

    func allProjects() throws -> [Project] {
        readCount += 1
        if readFails { throw ManualBriefTestRepositoryError.unavailable }
        return storedProject.map { [$0] } ?? []
    }

    func save(_ project: Project) { writeCount += 1 }
    func delete(id: UUID) { writeCount += 1 }
}

private actor CountingTransitionRepository: WorkStateTransitionRepository {
    let storedProposals: [WorkStateTransitionProposal]
    let storedGroups: [WorkStateAmbiguousMatchGroup]
    let storedAmbiguityReviews: [UUID: WorkStateAmbiguityReviewState]
    let readFails: Bool
    private(set) var projectProposalReadCount = 0
    private(set) var projectAmbiguityReadCount = 0
    private(set) var writeCount = 0

    init(
        proposals: [WorkStateTransitionProposal] = [],
        groups: [WorkStateAmbiguousMatchGroup] = [],
        ambiguityReviews: [WorkStateAmbiguityReviewState] = [],
        readFails: Bool = false
    ) {
        storedProposals = proposals
        storedGroups = groups
        storedAmbiguityReviews = Dictionary(uniqueKeysWithValues: ambiguityReviews.map { ($0.groupID, $0) })
        self.readFails = readFails
    }

    func proposals(forProject projectID: UUID) async throws -> [WorkStateTransitionProposal] {
        projectProposalReadCount += 1
        if readFails { throw ManualBriefTestRepositoryError.unavailable }
        return storedProposals.filter { $0.projectID == projectID }
    }

    func allProposals() async throws -> [WorkStateTransitionProposal] { storedProposals }

    // This double exists to count Brief *reads* over a fixed fixture. Deletion is a different
    // subject with its own tests, so these stay inert rather than pretending to mutate a `let`.
    func recordMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws {}
    func pendingMeetingDeletionIntents() async throws -> [MeetingDeletionIntent] { [] }
    func applyMeetingDeletion(_ intent: MeetingDeletionIntent) async throws {}
    func clearMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws {}
    func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) async throws {}
    func pendingProjectDeletionIntents() async throws -> [ProjectDeletionIntent] { [] }
    func applyProjectDeletion(_ intent: ProjectDeletionIntent) async throws {}

    func ambiguousMatchGroups(forProject projectID: UUID) async throws -> [WorkStateAmbiguousMatchGroup] {
        projectAmbiguityReadCount += 1
        if readFails { throw ManualBriefTestRepositoryError.unavailable }
        return storedGroups.filter { $0.projectID == projectID }
    }

    func allAmbiguousMatchGroups() async throws -> [WorkStateAmbiguousMatchGroup] { storedGroups }
    func ambiguityReview(groupID: UUID) async throws -> WorkStateAmbiguityReviewState? {
        storedAmbiguityReviews[groupID]
    }
    func refusals(forProject projectID: UUID) async throws -> [WorkStateTransitionRefusalRecord] { [] }
    func allRefusals() async throws -> [WorkStateTransitionRefusalRecord] { [] }
    func pendingApplyIntents() async throws -> [WorkStateTransitionApplyIntent] { [] }
    func prepareApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionApplyIntentWriteResult {
        writeCount += 1
        return .recorded
    }
    func finalizeApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionReviewWriteResult {
        writeCount += 1
        return .recorded
    }
    func upsert(_ proposals: [WorkStateTransitionProposal]) async throws { writeCount += 1 }
    func upsert(
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        refusals: [WorkStateTransitionRefusalRecord]
    ) async throws { writeCount += 1 }
    func recordTerminalReview(
        projectID: UUID,
        proposalID: UUID,
        verdict: WorkStateTransitionTerminalVerdict
    ) async throws -> WorkStateTransitionReviewWriteResult {
        writeCount += 1
        return .recorded
    }

    func recordTerminalReviews(
        projectID: UUID,
        reviews: [WorkStateTransitionTerminalReview]
    ) async throws -> WorkStateTransitionReviewWriteResult {
        writeCount += 1
        return .recorded
    }

    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) async throws -> WorkStateTransitionReviewWriteResult {
        writeCount += 1
        return .recorded
    }
}

private actor CountingProfileRepository: LocalUserProfileRepository {
    let storedProfile: LocalUserProfile?
    let readFails: Bool
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(profile: LocalUserProfile?, readFails: Bool = false) {
        storedProfile = profile
        self.readFails = readFails
    }

    func profile() throws -> LocalUserProfile? {
        readCount += 1
        if readFails { throw ManualBriefTestRepositoryError.unavailable }
        return storedProfile
    }

    func save(_ profile: LocalUserProfile) { writeCount += 1 }
}

private enum ManualBriefTestRepositoryError: Error {
    case unavailable
}
