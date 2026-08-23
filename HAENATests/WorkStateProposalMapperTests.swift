import XCTest
@testable import HAENA

final class WorkStateProposalMapperTests: XCTestCase {
    private let meeting = ExtractionFixtures.meeting()

    private func map(
        _ result: WorkStateExtractionResult,
        meeting: Meeting? = nil
    ) -> ValidatedWorkState {
        return WorkStateProposalMapper.map(
            result,
            meeting: meeting ?? self.meeting,
            now: TestFixtures.fixedDate
        ).workState
    }

    // MARK: - Happy path

    func testMapsAllFourKindsAsProposedWithEvidenceAndConfidence() {
        let state = map(ExtractionFixtures.fullResult(confidence: 0.75))

        XCTAssertEqual(state.decisions.count, 1)
        XCTAssertEqual(state.actionItems.count, 1)
        XCTAssertEqual(state.openQuestions.count, 1)
        XCTAssertEqual(state.agendaItems.count, 1)
        XCTAssertTrue(state.rejected.isEmpty)

        XCTAssertEqual(state.decisions[0].status, .proposed)
        XCTAssertEqual(state.actionItems[0].status, .proposed)
        // OpenQuestion has no `.proposed`; `.open` is its equivalent un-reviewed state.
        XCTAssertEqual(state.openQuestions[0].status, .open)
        XCTAssertEqual(state.agendaItems[0].status, .pending)

        XCTAssertEqual(state.decisions[0].confidence, Confidence(0.75))
        XCTAssertEqual(state.actionItems[0].confidence, Confidence(0.75))
        XCTAssertEqual(state.openQuestions[0].confidence, Confidence(0.75))
        XCTAssertEqual(state.agendaItems[0].confidence, Confidence(0.75))

        XCTAssertNotNil(state.decisions[0].evidence)
        XCTAssertNotNil(state.actionItems[0].evidence)
        XCTAssertNotNil(state.openQuestions[0].evidence)
        XCTAssertNotNil(state.agendaItems[0].evidence)
    }

    func testEvidencePointsAtTheCitedSegmentAndKeepsTheVerbatimQuote() {
        let state = map(ExtractionFixtures.fullResult())

        let evidence = try? XCTUnwrap(state.decisions[0].evidence)
        XCTAssertEqual(evidence?.meetingID, meeting.id)
        XCTAssertEqual(evidence?.transcriptSegmentID, TestFixtures.segmentID)
        XCTAssertEqual(evidence?.quote, "2월 출시로 가기로 했습니다")
    }

    func testIgnoresModelSuppliedIdentityAndAssignsAppGeneratedIDs() {
        let state = map(ExtractionFixtures.fullResult())

        let ids = [
            state.decisions[0].id,
            state.actionItems[0].id,
            state.openQuestions[0].id,
            state.agendaItems[0].id
        ]
        XCTAssertEqual(Set(ids).count, 4, "every stored item must get its own app-generated id")
        XCTAssertEqual(state.decisions[0].projectID, meeting.projectID)
        XCTAssertEqual(state.decisions[0].meetingID, meeting.id)
        XCTAssertEqual(state.agendaItems[0].sourceMeetingID, meeting.id)
    }

    func testEmptyResultProducesNothingAndRejectsNothing() {
        let state = map(ExtractionFixtures.emptyResult())

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.isEmpty)
    }

    // MARK: - Evidence validation

    func testRejectsQuoteThatIsNotInTheTranscript() {
        let result = ExtractionFixtures.fullResult(
            evidence: ExtractionFixtures.evidence(quote: "3월 출시로 가기로 했습니다")
        )

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.rejected.count, 4)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .quoteNotInTranscript })
    }

    func testRejectsEvidencePointingAtASegmentOutsideThisMeeting() {
        let result = ExtractionFixtures.fullResult(
            evidence: ExtractionFixtures.evidence(segmentID: UUID())
        )

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .unknownSegment })
    }

    func testRejectsMalformedSegmentIdentifier() {
        let result = ExtractionFixtures.fullResult(
            evidence: ProposedEvidence(segmentID: "not-a-uuid", quote: "2월 출시로 가기로 했습니다")
        )

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .unknownSegment })
    }

    func testRejectsEmptyQuote() {
        let result = ExtractionFixtures.fullResult(evidence: ExtractionFixtures.evidence(quote: "   "))

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .quoteNotInTranscript })
    }

    func testAcceptsQuoteWithSurroundingWhitespaceButStoresItTrimmed() {
        let result = ExtractionFixtures.fullResult(
            evidence: ExtractionFixtures.evidence(quote: "  2월 출시로 가기로 했습니다  ")
        )

        let state = map(result)

        XCTAssertEqual(state.decisions.count, 1)
        XCTAssertEqual(state.decisions[0].evidence?.quote, "2월 출시로 가기로 했습니다")
    }

    // MARK: - Confidence validation

    func testRejectsConfidenceAboveOne() {
        let state = map(ExtractionFixtures.fullResult(confidence: 1.5))

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .confidenceOutOfRange })
    }

    func testRejectsNegativeConfidence() {
        let state = map(ExtractionFixtures.fullResult(confidence: -0.1))

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .confidenceOutOfRange })
    }

    func testRejectsNonFiniteConfidence() {
        let state = map(ExtractionFixtures.fullResult(confidence: .nan))

        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.rejected.allSatisfy { $0.reason == .confidenceOutOfRange })
    }

    func testAcceptsConfidenceAtBothBounds() {
        XCTAssertEqual(map(ExtractionFixtures.fullResult(confidence: 0)).decisions.count, 1)
        XCTAssertEqual(map(ExtractionFixtures.fullResult(confidence: 1)).decisions.count, 1)
    }

    // MARK: - Partial failure

    func testKeepsVerifiableItemsWhenOtherItemsInTheSameResponseAreUngrounded() {
        let result = WorkStateExtractionResult(
            decisions: [
                ProposedDecision(
                    providerLocalKey: "decision_1",
                    statement: "검증되는 결정",
                    rationale: nil,
                    confidence: 0.6,
                    evidence: ExtractionFixtures.evidence()
                ),
                ProposedDecision(
                    providerLocalKey: "decision_2",
                    statement: "지어낸 결정",
                    rationale: nil,
                    confidence: 0.6,
                    evidence: ExtractionFixtures.evidence(quote: "회의록에 없는 문장")
                )
            ],
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "검증되는 업무",
                    details: nil,
                    assigneeAttribution: attribution(.unspecified),
                    dueDate: nil,
                    confidence: 2.0,
                    evidence: ExtractionFixtures.evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let state = map(result)

        XCTAssertEqual(state.decisions.count, 1)
        XCTAssertEqual(state.decisions[0].statement, "검증되는 결정")
        XCTAssertTrue(state.actionItems.isEmpty)
        XCTAssertEqual(state.rejected.count, 2)
        XCTAssertEqual(state.rejected[0], RejectedProposal(kind: .decision, reason: .quoteNotInTranscript))
        XCTAssertEqual(state.rejected[1], RejectedProposal(kind: .actionItem, reason: .confidenceOutOfRange))
    }

    func testRejectsItemWithEmptyContent() {
        let result = WorkStateExtractionResult(
            decisions: [
                ProposedDecision(
                    providerLocalKey: "decision_1",
                    statement: "   ",
                    rationale: nil,
                    confidence: 0.5,
                    evidence: ExtractionFixtures.evidence()
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.rejected, [RejectedProposal(kind: .decision, reason: .emptyContent)])
    }

    // MARK: - Evidence-first assignee attribution

    func testExplicitNameResolvesOnlyOneNormalizedExactDisplayName() throws {
        let participant = Participant(id: UUID(), displayName: "  Jose\u{301}  ", linkedUserID: nil, speakerLabel: "A")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let state = map(
            actionResult(attribution: attribution(.explicitName, reference: "JOSÉ")),
            meeting: meeting
        )

        let item = try XCTUnwrap(state.actionItems.first)
        XCTAssertEqual(item.assigneeID, participant.id)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
    }

    func testExplicitNameMayResolveAnExactSpeakerLabel() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(actionResult(attribution: attribution(.explicitName, reference: "b")), meeting: meeting)
                .actionItems.first
        )

        XCTAssertEqual(item.assigneeID, participant.id)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
    }

    func testExplicitNameDoesNotUseSubstringOrFuzzyMatching() throws {
        let participant = Participant(id: UUID(), displayName: "Jamie Kim", linkedUserID: nil, speakerLabel: "A")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(actionResult(attribution: attribution(.explicitName, reference: "Jamie")), meeting: meeting)
                .actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .noParticipantMatch)
    }

    func testExplicitNameKeepsItemUnassignedWhenMatchIsAmbiguous() throws {
        let first = Participant(id: UUID(), displayName: "Jamie", linkedUserID: nil, speakerLabel: "A")
        let second = Participant(id: UUID(), displayName: "다른 이름", linkedUserID: nil, speakerLabel: "Jamie")
        let meeting = ExtractionFixtures.meeting(participants: [first, second])

        let item = try XCTUnwrap(
            map(actionResult(attribution: attribution(.explicitName, reference: "Jamie")), meeting: meeting)
                .actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .ambiguousParticipantMatch)
    }

    func testMissingExplicitNameKeepsItemWithInvalidAttribution() throws {
        let item = try XCTUnwrap(
            map(actionResult(attribution: attribution(.explicitName, reference: "  "))).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .invalidAttribution)
        XCTAssertTrue(map(actionResult(attribution: attribution(.explicitName, reference: nil))).rejected.isEmpty)
    }

    func testSelfReferenceResolvesOnlyTheValidatedEvidenceSpeaker() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.selfReference, reference: "제가", speakerLabel: "B")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertEqual(item.assigneeID, participant.id)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
    }

    func testSpeakerCommitmentResolvesTheValidatedEvidenceSpeaker() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.speakerCommitment, speakerLabel: "B")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertEqual(item.assigneeID, participant.id)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
    }

    func testSpeakerCommitmentRequiresCharacterForCharacterSourceLabelMatch() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = meeting(
            participants: [participant],
            evidenceSpeakerID: participant.id,
            sourceSpeakerLabel: "Speaker B"
        )

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.speakerCommitment, speakerLabel: "speaker b")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .speakerLabelMismatch)
    }

    func testSelfReferenceWithoutEvidenceSpeakerKeepsItemUnassigned() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = meeting(participants: [participant], evidenceSpeakerID: nil)

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.selfReference, reference: "제가", speakerLabel: "B")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .missingEvidenceSpeaker)
    }

    func testSelfReferenceToSpeakerOutsideParticipantRosterKeepsItemUnassigned() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = meeting(participants: [participant], evidenceSpeakerID: UUID())

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.selfReference, reference: "제가", speakerLabel: "B")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .evidenceSpeakerNotParticipant)
    }

    func testSelfReferenceCannotClaimADifferentSpeakerLabel() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "A")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.selfReference, reference: "제가", speakerLabel: "B")),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .speakerLabelMismatch)
    }

    func testSelfReferenceWithoutProposedSpeakerLabelIsInvalidButKeepsItem() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let item = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.selfReference, reference: "제가", speakerLabel: nil)),
                meeting: meeting
            ).actionItems.first
        )

        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .invalidAttribution)
    }

    func testTeamOrRoleAndUnspecifiedNeverResolveAnIndividual() throws {
        let participant = Participant(id: UUID(), displayName: "플랫폼 팀", linkedUserID: nil, speakerLabel: "A")
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let team = try XCTUnwrap(
            map(
                actionResult(attribution: attribution(.teamOrRole, reference: "플랫폼 팀")),
                meeting: meeting
            ).actionItems.first
        )
        let unspecified = try XCTUnwrap(
            map(actionResult(attribution: attribution(.unspecified)), meeting: meeting).actionItems.first
        )

        XCTAssertNil(team.assigneeID)
        XCTAssertEqual(team.proposedAssigneeAttribution?.resolution, .nonIndividual)
        XCTAssertNil(unspecified.assigneeID)
        XCTAssertEqual(unspecified.proposedAssigneeAttribution?.resolution, .unspecified)
    }

    func testRawAttributionProvenanceIsPreservedWithoutNormalization() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])
        let proposed = attribution(.explicitName, reference: "  민수  ")

        let item = try XCTUnwrap(map(actionResult(attribution: proposed), meeting: meeting).actionItems.first)

        XCTAssertEqual(item.proposedAssigneeAttribution?.basis, .explicitName)
        XCTAssertEqual(item.proposedAssigneeAttribution?.reference, "  민수  ")
        XCTAssertNil(item.proposedAssigneeAttribution?.speakerLabel)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
    }

    func testInvalidBasisFieldCombinationsKeepItemUnassignedWithFiniteResolution() throws {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])
        let invalid: [ProposedAssigneeAttribution] = [
            attribution(.explicitName, reference: "민수", speakerLabel: "B"),
            attribution(.selfReference, reference: nil, speakerLabel: "B"),
            attribution(.selfReference, reference: "   ", speakerLabel: "B"),
            attribution(.speakerCommitment, reference: "   ", speakerLabel: "B"),
            attribution(.speakerCommitment, reference: nil, speakerLabel: nil),
            attribution(.teamOrRole, reference: nil),
            attribution(.teamOrRole, reference: "플랫폼 팀", speakerLabel: "B"),
            attribution(.unspecified, reference: "민수"),
            attribution(.unspecified, speakerLabel: "B")
        ]

        for proposed in invalid {
            let state = map(actionResult(attribution: proposed), meeting: meeting)
            let item = try XCTUnwrap(state.actionItems.first)
            XCTAssertNil(item.assigneeID, "invalid shape must not select a participant: \(proposed)")
            XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .invalidAttribution)
            XCTAssertTrue(state.rejected.isEmpty, "attribution failure must keep the action item")
        }
    }

    func testInvalidEvidenceRejectsActionBeforeOtherwiseResolvableAttribution() {
        let participant = Participant(id: UUID(), displayName: "민수", linkedUserID: nil, speakerLabel: "B")
        let meeting = ExtractionFixtures.meeting(participants: [participant])
        let result = actionResult(
            attribution: attribution(.selfReference, reference: "제가", speakerLabel: "B"),
            evidence: ProposedEvidence(segmentID: "not-a-uuid", quote: "2월 출시로 가기로 했습니다")
        )

        let state = map(result, meeting: meeting)

        XCTAssertTrue(state.actionItems.isEmpty)
        XCTAssertEqual(state.rejected, [RejectedProposal(kind: .actionItem, reason: .unknownSegment)])
    }

    func testLeavesDueDateNilWhenTheProposalHasNone() {
        let state = map(ExtractionFixtures.fullResult())

        XCTAssertNil(state.actionItems[0].dueDate, "an absent date must not become an invented one")
    }

    func testKeepsAStatedDueDate() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        let state = map(ExtractionFixtures.fullResult(dueDate: due))

        XCTAssertEqual(state.actionItems[0].dueDate, due)
    }

    // MARK: - Attribution fixtures

    private func attribution(
        _ basis: AssigneeAttributionBasis,
        reference: String? = nil,
        speakerLabel: String? = nil
    ) -> ProposedAssigneeAttribution {
        ProposedAssigneeAttribution(basis: basis, reference: reference, speakerLabel: speakerLabel)
    }

    private func actionResult(
        attribution: ProposedAssigneeAttribution,
        evidence: ProposedEvidence = ExtractionFixtures.evidence(),
        confidence: Double = 0.8,
        dueDate: Date? = nil
    ) -> WorkStateExtractionResult {
        WorkStateExtractionResult(
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "지표 정의 초안 작성",
                    details: nil,
                    assigneeAttribution: attribution,
                    dueDate: dueDate,
                    confidence: confidence,
                    evidence: evidence
                )
            ],
            metadata: ExtractionFixtures.metadata
        )
    }

    private func meeting(
        participants: [Participant],
        evidenceSpeakerID: UUID?,
        sourceSpeakerLabel: String? = "B"
    ) -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Kickoff",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: [
                TranscriptSegment(
                    id: TestFixtures.segmentID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: evidenceSpeakerID,
                    sourceSpeakerLabel: sourceSpeakerLabel,
                    text: ExtractionFixtures.transcript,
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )
    }
}
