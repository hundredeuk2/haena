import XCTest
@testable import HAENA

final class WorkStateContinuitySignalMapperTests: XCTestCase {
    private let meeting = ExtractionFixtures.meeting(
        text: "기존 작업은 완료했습니다. 질문의 답은 출시입니다. 출시 결정에 따라 배포 작업을 진행합니다."
    )

    func testProviderLocalKeyContractRejectsBadSyntaxAndAcceptsCanonicalPositiveOrdinal() {
        XCTAssertTrue(WorkStateProposalMapper.isValidProviderLocalKey("decision_1", expectedKind: .decision))
        XCTAssertTrue(WorkStateProposalMapper.isValidProviderLocalKey("action_42", expectedKind: .actionItem))

        let invalid = [
            "decision_0", "decision_01", "Decision_1", "decision-name_1", "decision_한글",
            "action_1", "decision_1234567", "decision_123456789012345678901234"
        ]
        for key in invalid {
            XCTAssertFalse(
                WorkStateProposalMapper.isValidProviderLocalKey(key, expectedKind: .decision),
                "unexpectedly accepted \(key)"
            )
        }
    }

    func testDuplicateKeyAcrossPayloadRejectsBothBaseObjectsAndDependentSignalFinitely() {
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            actionItems: [action(key: "decision_1")],
            progressSignals: [
                ProposedProgressSignal(kind: .completed, targetType: .incomingActionItem, targetReference: "decision_1", evidence: evidence())
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result)

        XCTAssertTrue(mapped.workState.isEmpty)
        XCTAssertEqual(mapped.workState.rejected.map(\.reason), [.duplicateProposalKey, .duplicateProposalKey])
        XCTAssertEqual(
            mapped.continuitySignals.rejected,
            [RejectedContinuitySignal(kind: .progress, reason: .duplicateProposalKey)]
        )
    }

    func testDeterministicIdentityIsStableAndScopedByMeetingKindAndKey() {
        let first = map(WorkStateExtractionResult(decisions: [decision(key: "decision_1")], metadata: ExtractionFixtures.metadata))
        let rerun = map(WorkStateExtractionResult(decisions: [decision(key: "decision_1")], metadata: ExtractionFixtures.metadata))
        let otherKey = map(WorkStateExtractionResult(decisions: [decision(key: "decision_2")], metadata: ExtractionFixtures.metadata))
        let otherMeeting = ExtractionFixtures.meeting(
            id: UUID(uuidString: "99999999-0000-0000-0000-000000000001")!,
            text: meeting.transcriptSegments[0].text
        )
        let otherRun = WorkStateProposalMapper.map(
            WorkStateExtractionResult(decisions: [decision(key: "decision_1")], metadata: ExtractionFixtures.metadata),
            meeting: otherMeeting,
            now: TestFixtures.fixedDate
        )

        XCTAssertEqual(first.workState.decisions[0].id, rerun.workState.decisions[0].id)
        XCTAssertEqual(first.providerLocalKeyToDomainID["decision_1"], first.workState.decisions[0].id)
        XCTAssertNotEqual(first.workState.decisions[0].id, otherKey.workState.decisions[0].id)
        XCTAssertNotEqual(first.workState.decisions[0].id, otherRun.workState.decisions[0].id)
    }

    func testMapsAllThreeSignalKindsOnlyThroughAcceptedBaseAndPriorAllowList() throws {
        let priorQuestionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let priorDecisionID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            "prior_question_1": .init(kind: .openQuestion, domainID: priorQuestionID),
            "prior_decision_1": .init(kind: .decision, domainID: priorDecisionID)
        ])
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            actionItems: [action(key: "action_1")],
            progressSignals: [
                .init(kind: .completed, targetType: .incomingActionItem, targetReference: "action_1", evidence: evidence())
            ],
            openQuestionResolutionLinks: [
                .init(
                    priorOpenQuestionReference: "prior_question_1",
                    targetKind: .decision,
                    targetProviderLocalKey: "decision_1",
                    evidence: evidence()
                )
            ],
            decisionDerivedActionItemLinks: [
                .init(
                    sourceDecisionKey: nil,
                    priorDecisionReference: "prior_decision_1",
                    actionItemKey: "action_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result, priorReferenceMap: priorMap)

        XCTAssertEqual(mapped.continuitySignals.progressSignals.count, 1)
        XCTAssertEqual(
            mapped.continuitySignals.progressSignals[0].target,
            .incomingActionItem(mapped.workState.actionItems[0].id)
        )
        XCTAssertEqual(mapped.continuitySignals.openQuestionResolutionLinks[0].priorOpenQuestionID, priorQuestionID)
        XCTAssertEqual(mapped.continuitySignals.openQuestionResolutionLinks[0].targetObjectID, mapped.workState.decisions[0].id)
        XCTAssertEqual(mapped.continuitySignals.decisionDerivedActionItemLinks[0].decisionID, priorDecisionID)
        XCTAssertTrue(mapped.continuitySignals.rejected.isEmpty)
    }

    func testDanglingKeysUnknownPriorAndWrongTargetKindRejectOnlySignals() {
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            actionItems: [action(key: "action_1")],
            progressSignals: [
                .init(kind: .blocked, targetType: .incomingActionItem, targetReference: "action_404", evidence: evidence())
            ],
            openQuestionResolutionLinks: [
                .init(
                    priorOpenQuestionReference: "prior_question_404",
                    targetKind: .decision,
                    targetProviderLocalKey: "decision_1",
                    evidence: evidence()
                ),
                .init(
                    priorOpenQuestionReference: "prior_question_1",
                    targetKind: .actionItem,
                    targetProviderLocalKey: "decision_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            "prior_question_1": .init(kind: .openQuestion, domainID: UUID())
        ])

        let mapped = map(result, priorReferenceMap: priorMap)

        XCTAssertEqual(mapped.workState.decisions.count, 1)
        XCTAssertEqual(mapped.workState.actionItems.count, 1)
        XCTAssertEqual(
            mapped.continuitySignals.rejected.map(\.reason),
            [.unknownProposalKey, .unknownPriorReference, .invalidTargetKind]
        )
    }

    func testForeignAndMissingEvidenceRejectSignalsWithoutBlockingBase() {
        let result = WorkStateExtractionResult(
            actionItems: [action(key: "action_1")],
            progressSignals: [
                .init(
                    kind: .deferred,
                    targetType: .incomingActionItem, targetReference: "action_1",
                    evidence: ProposedEvidence(segmentID: UUID().uuidString, quote: "기존 작업은 완료했습니다")
                ),
                .init(kind: .blocked, targetType: .incomingActionItem, targetReference: "action_1", evidence: nil),
                .init(
                    kind: .completed,
                    targetType: .incomingActionItem, targetReference: "action_1",
                    evidence: ProposedEvidence(segmentID: TestFixtures.segmentID.uuidString, quote: "없는 인용")
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result)

        XCTAssertEqual(mapped.workState.actionItems.count, 1)
        XCTAssertTrue(mapped.continuitySignals.progressSignals.isEmpty)
        XCTAssertEqual(
            mapped.continuitySignals.rejected.map(\.reason),
            [.foreignMeetingEvidence, .missingEvidence, .missingEvidence]
        )
    }

    func testRejectedBaseMakesDependentSignalDanglingButOtherBaseSurvives() {
        let badAction = ProposedActionItem(
            providerLocalKey: "action_1",
            title: "배포 작업",
            details: nil,
            assigneeAttribution: .init(basis: .unspecified, reference: nil, speakerLabel: nil),
            dueDate: nil,
            confidence: 0.8,
            evidence: ProposedEvidence(segmentID: UUID().uuidString, quote: "배포 작업")
        )
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            actionItems: [badAction],
            progressSignals: [.init(kind: .completed, targetType: .incomingActionItem, targetReference: "action_1", evidence: evidence())],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result)

        XCTAssertEqual(mapped.workState.decisions.count, 1)
        XCTAssertTrue(mapped.workState.actionItems.isEmpty)
        XCTAssertEqual(mapped.continuitySignals.rejected.map(\.reason), [.unknownProposalKey])
    }

    func testDerivedSourceRequiresExactlyOneReference() {
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            actionItems: [action(key: "action_1")],
            decisionDerivedActionItemLinks: [
                .init(
                    sourceDecisionKey: "decision_1",
                    priorDecisionReference: "prior_decision_1",
                    actionItemKey: "action_1",
                    evidence: evidence()
                ),
                .init(
                    sourceDecisionKey: nil,
                    priorDecisionReference: nil,
                    actionItemKey: "action_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result)

        XCTAssertEqual(
            mapped.continuitySignals.rejected,
            [
                .init(kind: .decisionDerivedActionItem, reason: .ambiguousSourceReference),
                .init(kind: .decisionDerivedActionItem, reason: .ambiguousSourceReference)
            ]
        )
    }

    func testFreshSnapshotRevalidationDropsOnlyStalePriorLinks() {
        let priorQuestionID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let priorDecisionID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            "prior_question_1": .init(kind: .openQuestion, domainID: priorQuestionID),
            "prior_decision_1": .init(kind: .decision, domainID: priorDecisionID)
        ])
        let mapped = map(
            WorkStateExtractionResult(
                actionItems: [action(key: "action_1")],
                openQuestionResolutionLinks: [
                    .init(
                        priorOpenQuestionReference: "prior_question_1",
                        targetKind: .actionItem,
                        targetProviderLocalKey: "action_1",
                        evidence: evidence()
                    )
                ],
                decisionDerivedActionItemLinks: [
                    .init(
                        sourceDecisionKey: nil,
                        priorDecisionReference: "prior_decision_1",
                        actionItemKey: "action_1",
                        evidence: evidence()
                    )
                ],
                metadata: ExtractionFixtures.metadata
            ),
            priorReferenceMap: priorMap
        )
        let nowEmpty = ApprovedWorkStateSnapshot(
            projectID: meeting.projectID,
            decisions: [],
            actionItems: [],
            openQuestions: [],
            agendaItems: []
        )

        let fresh = mapped.continuitySignals.revalidated(against: nowEmpty, incoming: mapped.workState)

        XCTAssertTrue(fresh.openQuestionResolutionLinks.isEmpty)
        XCTAssertTrue(fresh.decisionDerivedActionItemLinks.isEmpty)
        XCTAssertEqual(fresh.rejected.map(\.reason), [.stalePriorState, .stalePriorState])
        XCTAssertEqual(mapped.workState.actionItems.count, 1)
    }

    func testPriorContextExposesOnlyMinimalApprovedDecisionActionAndQuestionData() {
        let decision = priorDecision()
        let action = priorAction()
        let question = priorQuestion()
        let agenda = priorAgenda()
        let snapshot = ApprovedWorkStateSnapshot(
            projectID: meeting.projectID,
            decisions: [decision],
            actionItems: [action],
            openQuestions: [question],
            agendaItems: [agenda]
        )

        let context = PriorWorkStateContext(snapshot: snapshot)

        XCTAssertEqual(Set(context.providerReferences.map(\.opaqueReference)), [
            "prior_decision_1", "prior_action_1", "prior_question_1"
        ])
        XCTAssertFalse(context.providerReferences.contains { $0.displayText.contains(decision.id.uuidString) })
        XCTAssertNil(context.referenceMap.domainReference(for: "prior_agenda_1"))
        XCTAssertEqual(
            context.referenceMap.domainReference(for: "prior_question_1"),
            .init(kind: .openQuestion, domainID: question.id)
        )
    }

    // MARK: - Prior-state direct references

    /// The whole point of the prior-target form: a meeting that only reports on existing work
    /// extracts no action item, and the signal still has to land on the approved prior item.
    func testPriorTargetProgressSignalResolvesWithoutAnyIncomingActionItem() {
        let prior = priorActionItem()
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            "prior_action_1": .init(kind: .actionItem, domainID: prior.id)
        ])
        let result = WorkStateExtractionResult(
            progressSignals: [
                .init(
                    kind: .completed,
                    targetType: .priorActionItem,
                    targetReference: "prior_action_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result, priorReferenceMap: priorMap)

        XCTAssertTrue(mapped.workState.actionItems.isEmpty, "A status report must not invent a task")
        XCTAssertEqual(mapped.continuitySignals.progressSignals.count, 1)
        XCTAssertEqual(mapped.continuitySignals.progressSignals[0].target, .priorActionItem(prior.id))
        XCTAssertTrue(mapped.continuitySignals.rejected.isEmpty)
    }

    func testUnknownAndWrongKindPriorReferencesRejectOnlyTheirOwnSignal() {
        let priorQuestionID = UUID(uuidString: "30000000-0000-0000-0000-000000000009")!
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            // A question reference under an action-shaped name: resolvable, but the wrong kind.
            "prior_action_2": .init(kind: .openQuestion, domainID: priorQuestionID)
        ])
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            progressSignals: [
                .init(
                    kind: .completed,
                    targetType: .priorActionItem,
                    targetReference: "prior_action_404",
                    evidence: evidence()
                ),
                .init(
                    kind: .blocked,
                    targetType: .priorActionItem,
                    targetReference: "prior_action_2",
                    evidence: evidence()
                )
            ],
            decisionChangeLinks: [
                .init(
                    priorDecisionReference: "prior_decision_404",
                    decisionKey: "decision_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result, priorReferenceMap: priorMap)

        XCTAssertEqual(mapped.workState.decisions.count, 1, "A rejected signal must not drop its base object")
        XCTAssertTrue(mapped.continuitySignals.progressSignals.isEmpty)
        XCTAssertTrue(mapped.continuitySignals.decisionChangeLinks.isEmpty)
        XCTAssertEqual(
            mapped.continuitySignals.rejected,
            [
                .init(kind: .progress, reason: .unknownPriorReference),
                .init(kind: .progress, reason: .unknownPriorReference),
                .init(kind: .decisionChange, reason: .unknownPriorReference)
            ]
        )
    }

    func testDecisionChangeLinkResolvesPriorAndIncomingDecisions() {
        let prior = priorDecision()
        let priorMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [
            "prior_decision_1": .init(kind: .decision, domainID: prior.id)
        ])
        let result = WorkStateExtractionResult(
            decisions: [decision(key: "decision_1")],
            decisionChangeLinks: [
                .init(
                    priorDecisionReference: "prior_decision_1",
                    decisionKey: "decision_1",
                    evidence: evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = map(result, priorReferenceMap: priorMap)

        XCTAssertEqual(mapped.continuitySignals.decisionChangeLinks.count, 1)
        XCTAssertEqual(mapped.continuitySignals.decisionChangeLinks[0].priorDecisionID, prior.id)
        XCTAssertEqual(
            mapped.continuitySignals.decisionChangeLinks[0].incomingDecisionID,
            mapped.workState.decisions[0].id
        )
        XCTAssertTrue(mapped.continuitySignals.rejected.isEmpty)
    }

    // MARK: - Fixtures

    private func priorActionItem() -> ActionItem {
        ActionItem(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            projectID: meeting.projectID,
            meetingID: meeting.id,
            title: "배포 작업",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .confirmed,
            evidence: nil,
            confidence: .maximum,
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func map(
        _ result: WorkStateExtractionResult,
        priorReferenceMap: PriorWorkStateReferenceMap = .empty
    ) -> ValidatedWorkStateExtraction {
        WorkStateProposalMapper.map(
            result,
            meeting: meeting,
            now: TestFixtures.fixedDate,
            priorReferenceMap: priorReferenceMap
        )
    }

    private func evidence() -> ProposedEvidence {
        ProposedEvidence(
            segmentID: TestFixtures.segmentID.uuidString,
            quote: "기존 작업은 완료했습니다"
        )
    }

    private func decision(key: String) -> ProposedDecision {
        ProposedDecision(
            providerLocalKey: key,
            statement: "출시 결정",
            rationale: nil,
            confidence: 0.9,
            evidence: evidence()
        )
    }

    private func action(key: String) -> ProposedActionItem {
        ProposedActionItem(
            providerLocalKey: key,
            title: "배포 작업",
            details: nil,
            assigneeAttribution: .init(basis: .unspecified, reference: nil, speakerLabel: nil),
            dueDate: nil,
            confidence: 0.9,
            evidence: evidence()
        )
    }

    private func priorDecision() -> Decision {
        Decision(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            projectID: meeting.projectID,
            meetingID: UUID(),
            statement: "이전 결정",
            rationale: nil,
            status: .confirmed,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func priorAction() -> ActionItem {
        ActionItem(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            projectID: meeting.projectID,
            meetingID: UUID(),
            title: "이전 작업",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .inProgress,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func priorQuestion() -> OpenQuestion {
        OpenQuestion(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            projectID: meeting.projectID,
            meetingID: UUID(),
            question: "이전 질문",
            status: .open,
            evidence: nil,
            confidence: Confidence(1),
            createdAt: TestFixtures.fixedDate,
            resolvedAt: nil,
            reviewedAt: TestFixtures.fixedDate
        )
    }

    private func priorAgenda() -> AgendaItem {
        AgendaItem(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
            projectID: meeting.projectID,
            title: "이전 안건",
            reason: "이전 이유",
            sourceMeetingID: nil,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: TestFixtures.fixedDate,
            reviewedAt: TestFixtures.fixedDate
        )
    }
}
