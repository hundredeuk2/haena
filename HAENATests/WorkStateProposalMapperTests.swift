import XCTest
@testable import HAENA

final class WorkStateProposalMapperTests: XCTestCase {
    private let meeting = ExtractionFixtures.meeting()

    private func map(
        _ result: WorkStateExtractionResult,
        meeting: Meeting? = nil
    ) -> ValidatedWorkState {
        var counter = 0
        return WorkStateProposalMapper.map(
            result,
            meeting: meeting ?? self.meeting,
            now: TestFixtures.fixedDate,
            makeID: {
                counter += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
            }
        )
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
                    statement: "검증되는 결정",
                    rationale: nil,
                    confidence: 0.6,
                    evidence: ExtractionFixtures.evidence()
                ),
                ProposedDecision(
                    statement: "지어낸 결정",
                    rationale: nil,
                    confidence: 0.6,
                    evidence: ExtractionFixtures.evidence(quote: "회의록에 없는 문장")
                )
            ],
            actionItems: [
                ProposedActionItem(
                    title: "검증되는 업무",
                    details: nil,
                    assigneeName: nil,
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
                ProposedDecision(statement: "   ", rationale: nil, confidence: 0.5, evidence: ExtractionFixtures.evidence())
            ],
            metadata: ExtractionFixtures.metadata
        )

        let state = map(result)

        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.rejected, [RejectedProposal(kind: .decision, reason: .emptyContent)])
    }

    // MARK: - No guessing

    func testLeavesAssigneeUnsetWhenNoParticipantMatches() {
        let result = ExtractionFixtures.fullResult(assigneeName: "이헌득")

        let state = map(result)

        XCTAssertNil(state.actionItems[0].assigneeID, "an unmatched name must not invent an assignee")
    }

    func testResolvesAssigneeOnlyOnAnUnambiguousParticipantMatch() {
        let participant = Participant(id: UUID(), displayName: "Heondeuk", linkedUserID: nil, speakerLabel: nil)
        let meeting = ExtractionFixtures.meeting(participants: [participant])

        let state = map(ExtractionFixtures.fullResult(assigneeName: "heondeuk"), meeting: meeting)

        XCTAssertEqual(state.actionItems[0].assigneeID, participant.id)
    }

    func testLeavesAssigneeUnsetWhenTwoParticipantsShareTheName() {
        let first = Participant(id: UUID(), displayName: "Jamie", linkedUserID: nil, speakerLabel: nil)
        let second = Participant(id: UUID(), displayName: "Jamie", linkedUserID: nil, speakerLabel: nil)
        let meeting = ExtractionFixtures.meeting(participants: [first, second])

        let state = map(ExtractionFixtures.fullResult(assigneeName: "Jamie"), meeting: meeting)

        XCTAssertNil(state.actionItems[0].assigneeID)
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
}
