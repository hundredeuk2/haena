import XCTest
@testable import HAENA

/// Storage-level contract tests: a missing file is an empty store, `dedupKey` is the row identity
/// across process boundaries, one project's rows never leak into another's, order is deterministic,
/// a schema mismatch refuses rather than guesses, and no transcript text reaches this file.
final class WorkStateTransitionRepositoryTests: XCTestCase {
    private var testDirectory: URL!

    private let projectID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let otherProjectID = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let meetingID = UUID(uuidString: "AA1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let segmentID = UUID(uuidString: "BB1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    private let previousStateID = UUID(uuidString: "A1B2C3D4-E5F6-4789-8ABC-DEF012345678")!
    private let currentObjectID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        // A unique subdirectory under the system temp directory — never Application Support — so
        // these tests can never touch a real user's continuity store.
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-WorkStateTransitionRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private func fileURL() -> URL {
        testDirectory.appendingPathComponent("continuity-transitions.json")
    }

    // MARK: - Loading

    func testMissingFileLoadsAsAnEmptyStoreRatherThanFailing() async throws {
        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())

        let all = try await repository.allProposals()

        XCTAssertEqual(all, [])
    }

    func testUnsupportedSchemaVersionThrowsInsteadOfGuessing() async throws {
        let store = WorkStateTransitionStoreFile(schemaVersion: 999, proposals: [])
        try JSONEncoder().encode(store).write(to: fileURL())

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())

        do {
            _ = try await repository.allProposals()
            XCTFail("Expected unsupportedSchemaVersion")
        } catch JSONRepositoryError.unsupportedSchemaVersion(let found, let supported) {
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, WorkStateTransitionStoreFile.currentSchemaVersion)
        }
    }

    // MARK: - Upsert

    func testUpsertedProposalsSurviveANewRepositoryInstance() async throws {
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .same)

        let writer = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await writer.upsert([proposal])

        // A brand-new instance over the same file stands in for "app relaunched": idempotency has
        // to hold across processes, not just within one cache.
        let reader = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let all = try await reader.allProposals()

        XCTAssertEqual(all, [proposal])
    }

    func testUpsertingTheSameDedupKeyKeepsOriginalCreatedAtAndRefreshesEnginePayload() async throws {
        let first = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .changed,
            basis: .nearTextMatch,
            reasons: [.similarityOnly],
            createdAt: fixedDate
        )
        let second = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .changed,
            basis: .exactNormalizedTextMatch,
            reasons: [.ambiguousPriorCandidates],
            createdAt: fixedDate.addingTimeInterval(500)
        )
        XCTAssertEqual(first.dedupKey, second.dedupKey, "fixtures must share a dedup key")

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert([first])
        try await repository.upsert([second])

        let all = try await repository.allProposals()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.basis, second.basis)
        XCTAssertEqual(all.first?.reasons, second.reasons)
        XCTAssertEqual(all.first?.createdAt, first.createdAt)
    }

    func testApprovedAndRejectedReviewStatesSurvivePendingEngineUpserts() async throws {
        let approved = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .changed,
            reviewStatus: .approved
        )
        let rejected = makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            reviewStatus: .rejected
        )
        let approvedRerun = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .changed,
            basis: .nearTextMatch,
            reasons: [.similarityOnly],
            reviewStatus: .pendingReview,
            createdAt: fixedDate.addingTimeInterval(500)
        )
        let rejectedRerun = makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            basis: .nearTextMatch,
            reasons: [.similarityOnly],
            reviewStatus: .pendingReview,
            createdAt: fixedDate.addingTimeInterval(500)
        )

        let writer = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await writer.upsert([approved, rejected])
        try await writer.upsert([approvedRerun, rejectedRerun])

        let restarted = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let reloaded = try await restarted.allProposals()
        let storedApproved = try XCTUnwrap(reloaded.first { $0.workStateKind == .actionItem })
        let storedRejected = try XCTUnwrap(reloaded.first { $0.workStateKind == .decision })
        XCTAssertEqual(storedApproved.reviewStatus, .approved)
        XCTAssertEqual(storedRejected.reviewStatus, .rejected)
        XCTAssertEqual(storedApproved.createdAt, approved.createdAt)
        XCTAssertEqual(storedRejected.createdAt, rejected.createdAt)
        XCTAssertEqual(
            storedApproved.basis,
            approved.basis,
            "a terminal verdict remains attached to the exact payload the user reviewed"
        )
    }

    func testSchemaOneRowsMigrateReviewStateWithoutLosingCreatedAt() async throws {
        struct LegacyStore: Codable {
            let schemaVersion: Int
            let proposals: [WorkStateTransitionProposal]
        }
        let legacy = makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            reviewStatus: .rejected
        )
        try JSONEncoder().encode(
            LegacyStore(schemaVersion: 1, proposals: [legacy])
        ).write(to: fileURL())

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let loaded = try await repository.allProposals()
        let migrated = try XCTUnwrap(loaded.first)
        XCTAssertEqual(migrated.reviewStatus, .rejected)
        XCTAssertEqual(migrated.createdAt, legacy.createdAt)

        // A write upgrades the envelope and keeps the lifted review separate.
        try await repository.upsert([makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            createdAt: fixedDate.addingTimeInterval(100)
        )])
        let decoded = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self,
            from: Data(contentsOf: fileURL())
        )
        XCTAssertEqual(decoded.schemaVersion, WorkStateTransitionStoreFile.currentSchemaVersion)
        XCTAssertEqual(decoded.reviews.first?.status, .rejected)
        XCTAssertTrue(decoded.proposals.allSatisfy { $0.reviewStatus == .pendingReview })
    }

    func testSchemaTwoRowsMigrateWithoutLosingReviewGroupsOrRefusals() async throws {
        struct SchemaTwoStore: Codable {
            let schemaVersion: Int
            let proposals: [WorkStateTransitionProposal]
            let reviews: [WorkStateTransitionReviewState]
            let ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup]
            let refusals: [WorkStateTransitionRefusalRecord]
        }
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let group = WorkStateAmbiguousMatchGroup(
            projectID: projectID,
            sourceMeetingID: meetingID,
            workStateKind: .decision,
            incomingObjectID: currentObjectID,
            priorCandidateIDs: [previousStateID]
        )
        let refusal = WorkStateTransitionRefusalRecord(
            run: WorkStateContinuityRunIdentity(projectID: projectID, sourceMeetingID: meetingID),
            refusal: WorkStateTransitionRefusal(
                workStateKind: .decision,
                attemptedTransition: .changed,
                previousStateID: previousStateID,
                currentObjectID: currentObjectID,
                reason: .similarityOnly
            ),
            createdAt: fixedDate
        )
        try JSONEncoder().encode(SchemaTwoStore(
            schemaVersion: 2,
            proposals: [proposal],
            reviews: [WorkStateTransitionReviewState(dedupKey: proposal.dedupKey, status: .approved)],
            ambiguousMatchGroups: [group],
            refusals: [refusal]
        )).write(to: fileURL())

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let loadedProposals = try await repository.allProposals()
        let loadedGroups = try await repository.allAmbiguousMatchGroups()
        let loadedRefusals = try await repository.allRefusals()
        XCTAssertEqual(loadedProposals.first?.reviewStatus, .approved)
        XCTAssertEqual(loadedGroups, [group])
        XCTAssertEqual(loadedRefusals, [refusal])

        try await repository.upsert([proposal])
        let migrated = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self, from: Data(contentsOf: fileURL())
        )
        XCTAssertEqual(migrated.schemaVersion, WorkStateTransitionStoreFile.currentSchemaVersion)
        XCTAssertTrue(migrated.ambiguityReviews.isEmpty)
    }

    func testSchemaThreeRowsLoadWithNoApplyIntentsAndPersistAsCurrentSchema() async throws {
        struct SchemaThreeStore: Codable {
            let schemaVersion: Int
            let proposals: [WorkStateTransitionProposal]
            let reviews: [WorkStateTransitionReviewState]
            let ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup]
            let ambiguityReviews: [WorkStateAmbiguityReviewState]
            let refusals: [WorkStateTransitionRefusalRecord]
        }
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let legacy = SchemaThreeStore(
            schemaVersion: 3,
            proposals: [proposal],
            reviews: [],
            ambiguousMatchGroups: [],
            ambiguityReviews: [],
            refusals: []
        )
        try JSONEncoder().encode(legacy).write(to: fileURL())
        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())

        let loadedProposals = try await repository.allProposals()
        let loadedIntents = try await repository.pendingApplyIntents()
        XCTAssertEqual(loadedProposals, [proposal])
        XCTAssertTrue(loadedIntents.isEmpty)
        try await repository.upsert([proposal])

        let persisted = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self,
            from: Data(contentsOf: fileURL())
        )
        XCTAssertEqual(persisted.schemaVersion, WorkStateTransitionStoreFile.currentSchemaVersion)
        XCTAssertEqual(persisted.proposals.count, 1)
        XCTAssertTrue(persisted.applyIntents.isEmpty)
    }

    func testTerminalDeferredPayloadCannotBecomeBlockedOnRerun() async throws {
        let deferred = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .delayed,
            basis: .structuredProgressSignal,
            progressDisposition: .deferred
        )
        let blocked = makeProposal(
            workStateKind: .actionItem,
            transitionKind: .delayed,
            basis: .structuredProgressSignal,
            progressDisposition: .blocked,
            createdAt: fixedDate.addingTimeInterval(100)
        )
        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert([deferred])
        let approvalResult = try await repository.recordTerminalReview(
            projectID: projectID, proposalID: deferred.id, verdict: .approved
        )
        XCTAssertEqual(approvalResult, .recorded)
        try await repository.upsert([blocked])

        let storedRows = try await repository.allProposals()
        let stored = try XCTUnwrap(storedRows.first)
        XCTAssertEqual(stored.progressDisposition, .deferred)
        XCTAssertEqual(stored.reviewStatus, .approved)
        XCTAssertEqual(stored.createdAt, fixedDate)

        let rejectedRepository = InMemoryWorkStateTransitionRepository(proposals: [deferred])
        let rejectionResult = try await rejectedRepository.recordTerminalReview(
            projectID: projectID, proposalID: deferred.id, verdict: .rejected
        )
        XCTAssertEqual(rejectionResult, .recorded)
        try await rejectedRepository.upsert([blocked])
        let rejectedRows = try await rejectedRepository.allProposals()
        let rejectedStored = try XCTUnwrap(rejectedRows.first)
        XCTAssertEqual(rejectedStored.progressDisposition, .deferred)
        XCTAssertEqual(rejectedStored.reviewStatus, .rejected)
    }

    func testTerminalReviewIsIdempotentAndCannotFlip() async throws {
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let repository = InMemoryWorkStateTransitionRepository(proposals: [proposal])

        let first = try await repository.recordTerminalReview(
            projectID: projectID, proposalID: proposal.id, verdict: .rejected
        )
        let same = try await repository.recordTerminalReview(
            projectID: projectID, proposalID: proposal.id, verdict: .rejected
        )
        let flip = try await repository.recordTerminalReview(
            projectID: projectID, proposalID: proposal.id, verdict: .approved
        )
        XCTAssertEqual(first, .recorded)
        XCTAssertEqual(same, .alreadyRecorded)
        XCTAssertEqual(flip, .refused(.terminalVerdictConflict))
    }

    func testPreparedApplyIntentFinalizesVerdictAndRemovesIntent() async throws {
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let repository = InMemoryWorkStateTransitionRepository(proposals: [proposal])
        let intent = WorkStateTransitionApplyIntent.proposal(
            projectID: projectID,
            proposalID: proposal.id,
            terminalReviews: [.init(proposalID: proposal.id, verdict: .approved)],
            reviewedAt: fixedDate
        )

        XCTAssertTrue(intent.hasValidPayloadHash)
        let prepared = try await repository.prepareApplyIntent(intent)
        let pending = try await repository.pendingApplyIntents()
        let finalized = try await repository.finalizeApplyIntent(intent)
        let remaining = try await repository.pendingApplyIntents()
        let proposals = await repository.allProposals()
        XCTAssertEqual(prepared, .recorded)
        XCTAssertEqual(pending, [intent])
        XCTAssertEqual(finalized, .recorded)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(proposals.first?.reviewStatus, .approved)
    }

    func testPreparedApplyIntentSurvivesRestartAndFinalizesInOnePersistedWrite() async throws {
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let intent = WorkStateTransitionApplyIntent.proposal(
            projectID: projectID,
            proposalID: proposal.id,
            terminalReviews: [.init(proposalID: proposal.id, verdict: .approved)],
            reviewedAt: fixedDate
        )
        let writer = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await writer.upsert([proposal])
        let prepared = try await writer.prepareApplyIntent(intent)
        XCTAssertEqual(prepared, .recorded)

        let restarted = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let pending = try await restarted.pendingApplyIntents()
        let finalized = try await restarted.finalizeApplyIntent(intent)
        XCTAssertEqual(pending, [intent])
        XCTAssertEqual(finalized, .recorded)

        let verified = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let remaining = try await verified.pendingApplyIntents()
        let stored = try await verified.allProposals()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(stored.first?.reviewStatus, .approved)
    }

    func testApplyIntentSidecarContainsOnlyFiniteMetadataAndNoPrivateText() async throws {
        let proposal = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let intent = WorkStateTransitionApplyIntent.proposal(
            projectID: projectID,
            proposalID: proposal.id,
            terminalReviews: [.init(proposalID: proposal.id, verdict: .approved)],
            reviewedAt: fixedDate
        )
        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert([proposal])
        _ = try await repository.prepareApplyIntent(intent)

        let store = try JSONDecoder().decode(
            WorkStateTransitionStoreFile.self,
            from: Data(contentsOf: fileURL())
        )
        XCTAssertEqual(store.applyIntents, [intent])
        let encodedIntent = String(
            data: try JSONEncoder().encode(store.applyIntents), encoding: .utf8
        )!
        XCTAssertFalse(encodedIntent.contains("transcript"))
        XCTAssertFalse(encodedIntent.contains("quote"))
        XCTAssertFalse(encodedIntent.contains("title"))
        XCTAssertFalse(encodedIntent.contains("name"))
    }

    func testAmbiguitySelectionPersistsAndAtomicallyReviewsSiblings() async throws {
        let secondPriorID = UUID(uuidString: "FFFFFFFF-89AB-CDEF-0123-456789ABCDEF")!
        let group = WorkStateAmbiguousMatchGroup(
            projectID: projectID,
            sourceMeetingID: meetingID,
            workStateKind: .decision,
            incomingObjectID: currentObjectID,
            priorCandidateIDs: [previousStateID, secondPriorID]
        )
        let first = makeProposal(workStateKind: .decision, transitionKind: .changed)
        let second = makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            previousStateID: secondPriorID
        )
        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert(proposals: [first, second], ambiguousMatchGroups: [group], refusals: [])

        let resolution = try await repository.resolveAmbiguity(
            projectID: projectID,
            groupID: group.id,
            selection: .priorCandidate(secondPriorID),
            reviewedAt: fixedDate
        )
        XCTAssertEqual(resolution, .recorded)
        let restarted = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let rows = try await restarted.allProposals()
        XCTAssertEqual(rows.first(where: { $0.previousStateID == previousStateID })?.reviewStatus, .rejected)
        XCTAssertEqual(rows.first(where: { $0.previousStateID == secondPriorID })?.reviewStatus, .approved)
        let ambiguityReview = try await restarted.ambiguityReview(groupID: group.id)
        XCTAssertEqual(
            ambiguityReview,
            WorkStateAmbiguityReviewState(
                groupID: group.id, projectID: projectID,
                selectionKind: .priorCandidate,
                selectedPriorStateID: secondPriorID, reviewedAt: fixedDate
            )
        )
    }

    func testRefusalsSurviveReloadAndSameRunDoesNotDuplicateThem() async throws {
        let refusal = WorkStateTransitionRefusal(
            workStateKind: .actionItem,
            attemptedTransition: .completed,
            previousStateID: previousStateID,
            currentObjectID: currentObjectID,
            reason: .unknownReferencedObject
        )
        let run = WorkStateContinuityRunIdentity(
            projectID: projectID,
            sourceMeetingID: meetingID
        )
        let first = WorkStateTransitionRefusalRecord(
            run: run,
            refusal: refusal,
            createdAt: fixedDate
        )
        let rerun = WorkStateTransitionRefusalRecord(
            run: run,
            refusal: refusal,
            createdAt: fixedDate.addingTimeInterval(500)
        )

        let writer = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await writer.upsert(proposals: [], ambiguousMatchGroups: [], refusals: [first])
        try await writer.upsert(proposals: [], ambiguousMatchGroups: [], refusals: [rerun])

        let restarted = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let stored = try await restarted.allRefusals()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.createdAt, first.createdAt)
        XCTAssertEqual(stored.first?.runID, run.runID)
        XCTAssertEqual(stored.first?.projectID, projectID)
        XCTAssertEqual(stored.first?.sourceMeetingID, meetingID)

        let contents = try String(contentsOf: fileURL(), encoding: .utf8)
        for forbiddenField in ["transcript", "quote", "title", "name", "freeText"] {
            XCTAssertFalse(contents.contains(forbiddenField))
        }
    }

    func testAmbiguousMatchGroupSurvivesReloadWithExplicitNewChoice() async throws {
        let anotherCandidateID = UUID(uuidString: "FFFFFFFF-89AB-CDEF-0123-456789ABCDEF")!
        let group = WorkStateAmbiguousMatchGroup(
            projectID: projectID,
            sourceMeetingID: meetingID,
            workStateKind: .decision,
            incomingObjectID: currentObjectID,
            priorCandidateIDs: [anotherCandidateID, previousStateID]
        )

        let writer = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await writer.upsert(
            proposals: [],
            ambiguousMatchGroups: [group],
            refusals: []
        )

        let restarted = JSONWorkStateTransitionRepository(fileURL: fileURL())
        let groups = try await restarted.allAmbiguousMatchGroups()
        let stored = try XCTUnwrap(groups.first)
        XCTAssertEqual(stored, group)
        XCTAssertTrue(stored.availableSelections.contains(.new))
    }

    // MARK: - Reading

    func testProposalsForProjectDoNotLeakAnotherProjectsRows() async throws {
        let mine = makeProposal(workStateKind: .decision, transitionKind: .new)
        let theirs = makeProposal(
            projectID: otherProjectID,
            workStateKind: .decision,
            transitionKind: .new
        )

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert([mine, theirs])

        let ours = try await repository.proposals(forProject: projectID)
        let others = try await repository.proposals(forProject: otherProjectID)
        let all = try await repository.allProposals()

        XCTAssertEqual(ours, [mine])
        XCTAssertEqual(others, [theirs])
        XCTAssertEqual(all.count, 2)
    }

    func testProposalsAreReturnedSortedByDedupKeyAscending() async throws {
        // The work-state segment of the key is what differs, so the expected order is the raw
        // values sorted as strings: action_item < agenda_item < decision < open_question.
        let actionItem = makeProposal(workStateKind: .actionItem, transitionKind: .same)
        let agendaItem = makeProposal(workStateKind: .agendaItem, transitionKind: .same)
        let decision = makeProposal(workStateKind: .decision, transitionKind: .same)
        let openQuestion = makeProposal(workStateKind: .openQuestion, transitionKind: .same)

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        // Written in deliberately reverse order.
        try await repository.upsert([openQuestion, decision, agendaItem, actionItem])

        let all = try await repository.allProposals()

        XCTAssertEqual(all.map(\.dedupKey), [actionItem, agendaItem, decision, openQuestion].map(\.dedupKey))
        XCTAssertEqual(all.map(\.dedupKey), all.map(\.dedupKey).sorted())
    }

    // MARK: - Privacy

    func testStoredFileContainsNoTranscriptQuoteText() async throws {
        // The quote exists on the source object's `EvidenceReference` and is deliberately dropped
        // when the pointer is built, so it must be absent from the bytes on disk — and so must any
        // field that could ever carry one.
        let quote = "we agreed to cut the September scope"
        let evidence = EvidenceReference(
            meetingID: meetingID,
            transcriptSegmentID: segmentID,
            quote: quote
        )
        let pointer = TransitionEvidencePointer(
            meetingID: evidence.meetingID,
            transcriptSegmentID: evidence.transcriptSegmentID
        )
        let proposal = makeProposal(
            workStateKind: .decision,
            transitionKind: .changed,
            evidence: pointer
        )

        let repository = JSONWorkStateTransitionRepository(fileURL: fileURL())
        try await repository.upsert([proposal])

        let contents = try String(contentsOf: fileURL(), encoding: .utf8)

        XCTAssertFalse(contents.contains(quote))
        XCTAssertFalse(contents.contains("quote"))
        // The pointer itself is still there — dropping the quote must not drop traceability.
        XCTAssertTrue(contents.contains(segmentID.uuidString))
    }

    // MARK: - Fixtures

    private func makeProposal(
        projectID: UUID? = nil,
        workStateKind: WorkStateKind,
        transitionKind: WorkStateTransitionKind,
        evidence: TransitionEvidencePointer? = nil,
        basis: WorkStateTransitionBasis = .exactNormalizedTextMatch,
        progressDisposition: WorkStateTransitionProgressDisposition? = nil,
        reasons: [WorkStateTransitionReason] = [],
        reviewStatus: WorkStateTransitionReviewStatus = .pendingReview,
        createdAt: Date? = nil,
        previousStateID: UUID? = nil
    ) -> WorkStateTransitionProposal {
        let owningProjectID = projectID ?? self.projectID
        let key = WorkStateTransitionProposal.dedupKey(
            projectID: owningProjectID,
            workStateKind: workStateKind,
            transitionKind: transitionKind,
            previousStateID: previousStateID ?? self.previousStateID,
            currentObjectID: currentObjectID
        )
        return WorkStateTransitionProposal(
            id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
            projectID: owningProjectID,
            workStateKind: workStateKind,
            transitionKind: transitionKind,
            previousStateID: previousStateID ?? self.previousStateID,
            currentObjectID: currentObjectID,
            sourceMeetingID: meetingID,
            evidence: evidence,
            basis: basis,
            progressDisposition: progressDisposition,
            reasons: reasons,
            requiresConfirmation: !reasons.isEmpty,
            reviewStatus: reviewStatus,
            relations: [],
            dedupKey: key,
            createdAt: createdAt ?? fixedDate
        )
    }
}
