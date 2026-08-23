import XCTest
@testable import HAENA

/// Regression tests for two matching defects found during integration review, both of which turned
/// a pair the engine should have linked into an unlinked `.new` row — the exact duplicate this
/// feature exists to prevent.
///
/// They live apart from `WorkStateTransitionEngineTests` on purpose. Those tests state the intended
/// rules; these two pin down specific inputs that once produced the wrong answer, and the reason
/// each one is here is only legible next to the failure it describes.
final class WorkStateTransitionMatchingBoundaryTests: XCTestCase {
    private let projectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let meetingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let segmentID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let priorID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private let incomingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A prior decision a user has already confirmed.
    private func priorDecision(_ statement: String) -> Decision {
        Decision(
            id: priorID,
            projectID: projectID,
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!,
            statement: statement,
            rationale: nil,
            status: .confirmed,
            evidence: nil,
            confidence: Confidence(0.9),
            createdAt: now,
            updatedAt: now
        )
    }

    /// A decision proposed by the new meeting, grounded in that meeting's transcript.
    private func incomingDecision(_ statement: String) -> Decision {
        Decision(
            id: incomingID,
            projectID: projectID,
            meetingID: meetingID,
            statement: statement,
            rationale: nil,
            status: .proposed,
            evidence: EvidenceReference(
                meetingID: meetingID,
                transcriptSegmentID: segmentID,
                quote: "…"
            ),
            confidence: Confidence(0.9),
            createdAt: now,
            updatedAt: now
        )
    }

    private func generate(prior: String, incoming: String) -> WorkStateTransitionEngineResult {
        WorkStateTransitionEngine.generate(
            WorkStateTransitionEngineInput(
                projectID: projectID,
                sourceMeetingID: meetingID,
                occurredAt: now,
                prior: ApprovedWorkStateSnapshot(
                    projectID: projectID,
                    decisions: [priorDecision(prior)],
                    actionItems: [],
                    openQuestions: [],
                    agendaItems: []
                ),
                incoming: ValidatedWorkState(decisions: [incomingDecision(incoming)])
            ),
            now: now
        )
    }

    /// Jaccard compares token *sets*, so a repeated word scores 1.0 against text it does not equal.
    /// The near-match band was originally bounded above by `< 1.0`, which dropped exactly this pair
    /// out of candidacy and emitted `.new` right beside the item it duplicates.
    func testRepeatedWordScoringOneStillCountsAsACandidateRatherThanANewDecision() throws {
        let result = generate(prior: "Fix the bug", incoming: "Fix the the bug")

        XCTAssertEqual(result.proposals.count, 1)
        let proposal = try XCTUnwrap(result.proposals.first)
        XCTAssertEqual(proposal.transitionKind, .changed)
        XCTAssertEqual(proposal.previousStateID, priorID)
        XCTAssertTrue(proposal.requiresConfirmation)
        XCTAssertNotEqual(
            proposal.transitionKind,
            .new,
            "A prior candidate exists, so this must never be reported as an unrelated new decision."
        )
    }

    /// Normalization collapses whitespace before stripping terminal punctuation, so "Ship it ."
    /// once became "Ship it " — a trailing space that no longer equalled "Ship it", demoting an
    /// exact match to a near one over nothing but a typed space.
    func testSpaceBeforeAFullStopStillCountsAsTheSameDecision() throws {
        let result = generate(prior: "Ship the beta", incoming: "Ship the beta .")

        XCTAssertEqual(result.proposals.count, 1)
        let proposal = try XCTUnwrap(result.proposals.first)
        XCTAssertEqual(proposal.transitionKind, .same)
        XCTAssertEqual(proposal.basis, .exactNormalizedTextMatch)
        XCTAssertFalse(
            proposal.requiresConfirmation,
            "An unambiguous exact match asserts that nothing changed, so it stays automatic."
        )
    }

    /// The normalization contract itself, stated directly: every difference it erases is a
    /// rendering difference, and none of them is a difference in meaning.
    func testNormalizationErasesOnlyRenderingDifferences() {
        XCTAssertEqual(
            WorkStateTransitionEngine.normalize("  Ship   the\nBeta.  "),
            WorkStateTransitionEngine.normalize("ship the beta")
        )
    }
}
