import XCTest
@testable import HAENA

/// Contract tests for the transition vocabulary: the dedup key's exact rendering, the determinism
/// of the derived id, the transition matrix table, the approval policy, and the on-disk coding
/// guarantees. Everything here asserts on the public contract other agents build against.
final class WorkStateTransitionDomainTests: XCTestCase {
    // Fixed UUIDs with uppercase letters in them, so lowercasing is actually observable.
    private let projectID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let otherProjectID = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let meetingID = UUID(uuidString: "AA1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let segmentID = UUID(uuidString: "BB1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let previousStateID = UUID(uuidString: "A1B2C3D4-E5F6-4789-8ABC-DEF012345678")!
    private let currentObjectID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Dedup key

    func testDedupKeyRendersLowercasedUUIDsAndSpellsNilAsNone() {
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .actionItem,
            transitionKind: .delayed,
            previousStateID: previousStateID,
            currentObjectID: nil
        )

        // Pinned character for character: this string is the row identity on disk, so any change to
        // its shape re-identifies every proposal a user has already reviewed.
        let expected = "haena.work-state-transition.v1|3f2504e0-4f89-11d3-9a0c-0305e82c3301|action_item|delayed|a1b2c3d4-e5f6-4789-8abc-def012345678|none"

        XCTAssertEqual(key, expected)
    }

    func testDedupKeyDistinguishesNilPreviousFromNilCurrent() {
        // Both fields nil-in-a-different-slot must not collapse onto the same key, otherwise a
        // "new" row and an "overdue prior item" row would overwrite each other.
        let missingPrevious = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .decision,
            transitionKind: .new,
            previousStateID: nil,
            currentObjectID: currentObjectID
        )
        let missingCurrent = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .decision,
            transitionKind: .new,
            previousStateID: currentObjectID,
            currentObjectID: nil
        )

        XCTAssertNotEqual(missingPrevious, missingCurrent)
    }

    // MARK: - Deterministic id

    func testDeterministicIDIsStableForTheSameDedupKey() {
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .openQuestion,
            transitionKind: .resolved,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID
        )

        let first = WorkStateTransitionProposal.deterministicID(forDedupKey: key)
        let second = WorkStateTransitionProposal.deterministicID(forDedupKey: key)

        XCTAssertEqual(first, second)
        // Pinned so a change to the derivation is a visible test failure rather than a silent
        // re-identification of every row already stored on a user's disk.
        XCTAssertEqual(first.uuidString.lowercased(), "c734e26b-f66d-56c4-af03-f9da34489d77")
    }

    func testDeterministicIDDiffersWhenOnlyTransitionKindDiffers() {
        let changed = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .actionItem,
            transitionKind: .changed,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID
        )
        let delayed = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .actionItem,
            transitionKind: .delayed,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID
        )

        XCTAssertNotEqual(
            WorkStateTransitionProposal.deterministicID(forDedupKey: changed),
            WorkStateTransitionProposal.deterministicID(forDedupKey: delayed)
        )
    }

    func testDeterministicIDIsAWellFormedVersion5RFC4122UUID() {
        let id = WorkStateTransitionProposal.deterministicID(
            forDedupKey: "haena.work-state-transition.v1|any|decision|new|none|none"
        )

        XCTAssertEqual(id.uuid.6 & 0xF0, 0x50, "version nibble must be 5")
        XCTAssertEqual(id.uuid.8 & 0xC0, 0x80, "RFC 4122 variant bits must be set")

        let characters = Array(id.uuidString.lowercased())
        XCTAssertEqual(characters[14], "5")
        XCTAssertTrue(["8", "9", "a", "b"].contains(String(characters[19])))
    }

    // MARK: - Transition matrix

    func testTransitionMatrixMatchesTheContractTableForEveryKindAndTransition() throws {
        let expected: [WorkStateKind: Set<WorkStateTransitionKind>] = [
            .decision: [.new, .same, .changed],
            .actionItem: [.new, .same, .changed, .completed, .delayed],
            .openQuestion: [.new, .same, .changed, .resolved],
            .agendaItem: [.new, .same]
        ]

        // Driven off CaseIterable so adding a work state or a transition without updating the
        // table is a failure rather than an untested cell.
        XCTAssertEqual(Set(expected.keys), Set(WorkStateKind.allCases))
        XCTAssertEqual(WorkStateTransitionKind.allCases.count, 6)

        for kind in WorkStateKind.allCases {
            let supported = try XCTUnwrap(expected[kind])
            XCTAssertEqual(WorkStateTransitionMatrix.supportedTransitions(for: kind), supported)

            for transition in WorkStateTransitionKind.allCases {
                XCTAssertEqual(
                    WorkStateTransitionMatrix.supports(transition, for: kind),
                    supported.contains(transition),
                    "\(kind.rawValue) x \(transition.rawValue)"
                )
            }
        }
    }

    // MARK: - Approval policy

    func testOnlyConfirmedDecisionsAreApprovedPriorState() {
        let statuses: [DecisionStatus] = [.proposed, .confirmed, .superseded, .rejected]

        for status in statuses {
            XCTAssertEqual(
                ApprovedWorkStatePolicy.isApproved(makeDecision(status: status)),
                status == .confirmed,
                status.rawValue
            )
        }
    }

    func testCompletedAndCancelledActionItemsAreNotApprovedPriorState() {
        let statuses: [ActionItemStatus] = [.proposed, .confirmed, .inProgress, .completed, .cancelled]

        for status in statuses {
            XCTAssertEqual(
                ApprovedWorkStatePolicy.isApproved(makeActionItem(status: status)),
                status == .confirmed || status == .inProgress,
                status.rawValue
            )
        }
    }

    func testOpenQuestionIsApprovedOnlyWhenOpenAndReviewed() {
        XCTAssertTrue(ApprovedWorkStatePolicy.isApproved(makeOpenQuestion(status: .open, reviewedAt: fixedDate)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeOpenQuestion(status: .open, reviewedAt: nil)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeOpenQuestion(status: .resolved, reviewedAt: fixedDate)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeOpenQuestion(status: .dismissed, reviewedAt: fixedDate)))
    }

    func testAgendaItemIsApprovedOnlyWhenPendingAndReviewed() {
        XCTAssertTrue(ApprovedWorkStatePolicy.isApproved(makeAgendaItem(status: .pending, reviewedAt: fixedDate)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeAgendaItem(status: .pending, reviewedAt: nil)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeAgendaItem(status: .resolved, reviewedAt: fixedDate)))
        XCTAssertFalse(ApprovedWorkStatePolicy.isApproved(makeAgendaItem(status: .dismissed, reviewedAt: fixedDate)))
    }

    func testSnapshotFromProjectDropsUnapprovedAndForeignProjectRecords() {
        let approvedDecision = makeDecision(status: .confirmed)
        let approvedActionItem = makeActionItem(status: .inProgress)
        let approvedQuestion = makeOpenQuestion(status: .open, reviewedAt: fixedDate)
        let approvedAgendaItem = makeAgendaItem(status: .pending, reviewedAt: fixedDate)

        let project = Project(
            id: projectID,
            name: "Continuity",
            summary: "",
            createdAt: fixedDate,
            updatedAt: fixedDate,
            meetings: [],
            decisions: [
                approvedDecision,
                makeDecision(status: .proposed),
                // Approved, but belongs to another project: a malformed store must not be able to
                // smuggle another project's item into this snapshot.
                makeDecision(status: .confirmed, projectID: otherProjectID)
            ],
            actionItems: [
                approvedActionItem,
                makeActionItem(status: .completed),
                makeActionItem(status: .confirmed, projectID: otherProjectID)
            ],
            openQuestions: [
                approvedQuestion,
                makeOpenQuestion(status: .open, reviewedAt: nil),
                makeOpenQuestion(status: .open, reviewedAt: fixedDate, projectID: otherProjectID)
            ],
            nextAgenda: [
                approvedAgendaItem,
                makeAgendaItem(status: .pending, reviewedAt: nil),
                makeAgendaItem(status: .pending, reviewedAt: fixedDate, projectID: otherProjectID)
            ]
        )

        let snapshot = ApprovedWorkStateSnapshot(project: project)

        XCTAssertEqual(snapshot.projectID, projectID)
        XCTAssertEqual(snapshot.decisions, [approvedDecision])
        XCTAssertEqual(snapshot.actionItems, [approvedActionItem])
        XCTAssertEqual(snapshot.openQuestions, [approvedQuestion])
        XCTAssertEqual(snapshot.agendaItems, [approvedAgendaItem])
    }

    // MARK: - Coding

    func testProposalRoundTripsThroughJSONUnchanged() throws {
        let proposal = makeProposal()

        let data = try JSONEncoder().encode(proposal)
        let decoded = try JSONDecoder().decode(WorkStateTransitionProposal.self, from: data)

        XCTAssertEqual(decoded, proposal)
    }

    func testDecodingAnUnknownEnumRawValueFailsInsteadOfDegrading() {
        // Wrapped in an array so this exercises the same decoding path a stored record uses.
        let unknown = Data("[\"a_case_from_the_future\"]".utf8)
        let decoder = JSONDecoder()

        XCTAssertThrowsError(try decoder.decode([WorkStateKind].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateTransitionKind].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateTransitionBasis].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateTransitionReason].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateTransitionReviewStatus].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateTransitionProgressDisposition].self, from: unknown))
        XCTAssertThrowsError(try decoder.decode([WorkStateRelationKind].self, from: unknown))
    }

    // MARK: - Fixtures

    private func makeDecision(status: DecisionStatus, projectID: UUID? = nil) -> Decision {
        Decision(
            id: UUID(),
            projectID: projectID ?? self.projectID,
            meetingID: meetingID,
            statement: "Ship the beta on Friday",
            rationale: nil,
            status: status,
            evidence: EvidenceReference(meetingID: meetingID, transcriptSegmentID: segmentID, quote: "quote"),
            confidence: Confidence(0.9),
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
    }

    private func makeActionItem(status: ActionItemStatus, projectID: UUID? = nil) -> ActionItem {
        ActionItem(
            id: UUID(),
            projectID: projectID ?? self.projectID,
            meetingID: meetingID,
            title: "Write the migration note",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: status,
            evidence: EvidenceReference(meetingID: meetingID, transcriptSegmentID: segmentID, quote: "quote"),
            confidence: Confidence(0.9),
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
    }

    private func makeOpenQuestion(
        status: OpenQuestionStatus,
        reviewedAt: Date?,
        projectID: UUID? = nil
    ) -> OpenQuestion {
        OpenQuestion(
            id: UUID(),
            projectID: projectID ?? self.projectID,
            meetingID: meetingID,
            question: "Who owns the rollout?",
            status: status,
            evidence: EvidenceReference(meetingID: meetingID, transcriptSegmentID: segmentID, quote: "quote"),
            confidence: Confidence(0.9),
            createdAt: fixedDate,
            resolvedAt: nil,
            reviewedAt: reviewedAt
        )
    }

    private func makeAgendaItem(
        status: AgendaItemStatus,
        reviewedAt: Date?,
        projectID: UUID? = nil
    ) -> AgendaItem {
        AgendaItem(
            id: UUID(),
            projectID: projectID ?? self.projectID,
            title: "Revisit the rollout owner",
            reason: "Carried from the last meeting",
            sourceMeetingID: meetingID,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: status,
            createdAt: fixedDate,
            reviewedAt: reviewedAt
        )
    }

    private func makeProposal() -> WorkStateTransitionProposal {
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: projectID,
            workStateKind: .openQuestion,
            transitionKind: .resolved,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID
        )
        return WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
            projectID: projectID,
            workStateKind: .openQuestion,
            transitionKind: .resolved,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID,
            sourceMeetingID: meetingID,
            evidence: TransitionEvidencePointer(meetingID: meetingID, transcriptSegmentID: segmentID),
            basis: .structuredResolutionLink,
            reasons: [.stateChangeRequiresApproval],
            requiresConfirmation: true,
            reviewStatus: .pendingReview,
            relations: [
                WorkStateTransitionRelation(
                    kind: .resolvedBy,
                    relatedKind: .decision,
                    relatedObjectID: currentObjectID
                )
            ],
            dedupKey: key,
            createdAt: fixedDate
        )
    }
}
