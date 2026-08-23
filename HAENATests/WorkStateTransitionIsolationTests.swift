import XCTest
@testable import HAENA

/// What a stored transition is allowed to contain, and what a later reader must be able to get
/// back out of it.
///
/// `continuity-transitions.json` is a second file next to `projects.json`, and it is the one the
/// follow-up Manual Continuity Brief will read long after the meeting is gone. That makes two
/// opposite failures possible, and this suite exists to rule out both:
///
/// - **Too much.** A transition that carried the quote it was derived from would be a second,
///   unmanaged copy of the transcript — and one that names people. The record therefore stores a
///   *pointer* to evidence, never evidence itself, and every explanation is a closed enum.
/// - **Too little.** A record that cannot say which project, which prior item, which new object,
///   on what basis and for what reason is a record the brief can only display, never explain.
///
/// The cross-project check belongs here too: isolation is not only an engine rule. A reader that
/// asked for one project's transitions and received another's would leak across the same boundary
/// the admission rules defend.
final class WorkStateTransitionIsolationTests: XCTestCase {

    private typealias Fixtures = WorkStateTransitionFixtures
    private typealias Representative = WorkStateTransitionFixtures.Representative

    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-WorkStateTransitionIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private func fileURL(_ name: String = "continuity-transitions.json") -> URL {
        testDirectory.appendingPathComponent(name)
    }

    // MARK: - Sentinels
    //
    // Every free-text string that flows into the engine is replaced by a marked value sharing one
    // prefix. A single containment check on the prefix then covers all of them at once, including
    // any partial or re-encoded leak that a per-string check might slip past.

    private static let sentinelPrefix = "zzsentinel"
    private static let sentinelDecisionStatement = "zzsentinel decision statement alpha"
    private static let sentinelTaskTitle = "zzsentinel task title bravo"
    private static let sentinelQuestion = "zzsentinel question charlie delta echo"
    /// One token different from `sentinelQuestion`, so it lands as a revision rather than a new
    /// question — a `changed` row is the one most likely to want to quote both texts.
    private static let sentinelRevisedQuestion = "zzsentinel question charlie delta foxtrot"
    private static let sentinelAgendaTitle = "zzsentinel agenda title golf"
    private static let sentinelAgendaReason = "zzsentinel agenda reason hotel"
    private static let sentinelPriorQuote = "zzsentinel quote from the earlier meeting"
    private static let sentinelSourceQuote = "zzsentinel quote from this meeting"
    private static let sentinelSignalQuote = "zzsentinel quote claiming completion"
    private static let sentinelPersonName = "zzsentinel person name india"
    private static let sentinelSpeakerLabel = "zzsentinel speaker label juliet"

    private static let allSentinels = [
        sentinelDecisionStatement, sentinelTaskTitle, sentinelQuestion, sentinelRevisedQuestion,
        sentinelAgendaTitle, sentinelAgendaReason, sentinelPriorQuote, sentinelSourceQuote,
        sentinelSignalQuote, sentinelPersonName, sentinelSpeakerLabel
    ]

    /// An input whose every human-readable string is a sentinel, producing rows of all four work
    /// state kinds plus a signal-derived row and an unresolved attribution.
    private func sentinelInput() -> WorkStateTransitionEngineInput {
        let priorDecisionID = Fixtures.uuid(300)
        let incomingDecisionID = Fixtures.uuid(301)
        let priorTaskID = Fixtures.uuid(302)
        let incomingTaskID = Fixtures.uuid(303)
        let priorQuestionID = Fixtures.uuid(304)
        let incomingQuestionID = Fixtures.uuid(305)
        let incomingAgendaID = Fixtures.uuid(306)

        let priorEvidence = EvidenceReference(
            meetingID: Fixtures.priorMeetingID,
            transcriptSegmentID: Fixtures.priorSegmentID,
            quote: Self.sentinelPriorQuote
        )
        let sourceEvidence = Fixtures.sourceEvidence(quote: Self.sentinelSourceQuote)
        let signalEvidence = Fixtures.signalEvidence(quote: Self.sentinelSignalQuote)

        // A name and a speaker label, on the one field that has ever carried either.
        let attribution = AssigneeAttribution(
            basis: .explicitName,
            reference: Self.sentinelPersonName,
            speakerLabel: Self.sentinelSpeakerLabel,
            resolution: .ambiguousParticipantMatch
        )

        return Fixtures.input(
            prior: Fixtures.snapshot(
                decisions: [
                    Fixtures.approvedDecision(
                        id: priorDecisionID,
                        statement: Self.sentinelDecisionStatement,
                        evidence: priorEvidence
                    )
                ],
                actionItems: [
                    Fixtures.approvedActionItem(
                        id: priorTaskID,
                        title: Self.sentinelTaskTitle,
                        evidence: priorEvidence
                    )
                ],
                openQuestions: [
                    Fixtures.approvedOpenQuestion(
                        id: priorQuestionID,
                        question: Self.sentinelQuestion,
                        evidence: priorEvidence
                    )
                ]
            ),
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(
                        id: incomingDecisionID,
                        statement: Self.sentinelDecisionStatement,
                        evidence: sourceEvidence
                    )
                ],
                actionItems: [
                    Fixtures.incomingActionItem(
                        id: incomingTaskID,
                        title: Self.sentinelTaskTitle,
                        attribution: attribution,
                        evidence: sourceEvidence
                    )
                ],
                openQuestions: [
                    Fixtures.incomingOpenQuestion(
                        id: incomingQuestionID,
                        question: Self.sentinelRevisedQuestion,
                        evidence: sourceEvidence
                    )
                ],
                agendaItems: [
                    Fixtures.incomingAgendaItem(
                        id: incomingAgendaID,
                        title: Self.sentinelAgendaTitle,
                        reason: Self.sentinelAgendaReason,
                        evidence: sourceEvidence
                    )
                ]
            ),
            progressSignals: [
                WorkStateProgressSignal(
                    kind: .completed,
                    actionItemID: incomingTaskID,
                    evidence: signalEvidence
                )
            ]
        )
    }

    // MARK: - Privacy

    func testPersistedTransitionsCarryNoTranscriptTitleOrPersonText() async throws {
        let url = fileURL()
        let input = sentinelInput()
        let result = WorkStateTransitionEngine.generate(input, now: Fixtures.generatedAt)
        WorkStateTransitionContract.assertInvariants(result, for: input)
        XCTAssertFalse(result.proposals.isEmpty, "an empty store would pass every check below")

        let repository = JSONWorkStateTransitionRepository(fileURL: url)
        try await repository.upsert(result.proposals)

        let raw = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))

        // Control: the file really does hold the rows, so the absence checks below are meaningful
        // rather than passing against an empty or mis-encoded payload.
        XCTAssertTrue(raw.contains("dedupKey") || raw.contains("dedup_key"))
        XCTAssertTrue(raw.contains(WorkStateTransitionReviewStatus.pendingReview.rawValue))
        XCTAssertTrue(raw.contains(WorkStateTransitionKind.same.rawValue))

        let lowercased = raw.lowercased()
        XCTAssertFalse(
            lowercased.contains(Self.sentinelPrefix),
            "no marked string may appear anywhere in the persisted transitions"
        )
        for sentinel in Self.allSentinels {
            XCTAssertFalse(lowercased.contains(sentinel.lowercased()), "leaked: \(sentinel)")
        }

        // And the pointer really is a pointer: the segment is named, the words are not.
        let same = try XCTUnwrap(result.proposals.first { $0.transitionKind == .same })
        XCTAssertEqual(same.evidence?.transcriptSegmentID, Fixtures.sourceSegmentID)
        XCTAssertTrue(raw.contains(Fixtures.sourceSegmentID.uuidString) ||
                      raw.contains(Fixtures.sourceSegmentID.uuidString.lowercased()))
    }

    func testEveryStoredExplanationIsAClosedEnumWithNoFreeTextField() async throws {
        let url = fileURL()
        let input = sentinelInput()
        let result = WorkStateTransitionEngine.generate(input, now: Fixtures.generatedAt)

        let repository = JSONWorkStateTransitionRepository(fileURL: url)
        try await repository.upsert(result.proposals)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["proposals"] as? [[String: Any]])
        XCTAssertEqual(rows.count, result.proposals.count)

        // Compared after normalisation so a camelCase or snake_case coding choice is not what this
        // test is about. What it is about: there is no *extra* key — in particular no note, no
        // detail, no free-text explanation anyone could later be tempted to fill with a quote.
        let allowedKeys = Set(
            [
                "id", "projectID", "workStateKind", "transitionKind", "previousStateID",
                "currentObjectID", "sourceMeetingID", "evidence", "basis", "reasons",
                "requiresConfirmation", "reviewStatus", "relations", "dedupKey", "createdAt"
            ].map(Self.normalizedKey)
        )
        let allowedEvidenceKeys = Set(["meetingID", "transcriptSegmentID"].map(Self.normalizedKey))
        let allowedRelationKeys = Set(["kind", "relatedKind", "relatedObjectID"].map(Self.normalizedKey))

        let reasonValues = Set(WorkStateTransitionReason.allCases.map(\.rawValue))
        let basisValues = Set(WorkStateTransitionBasis.allCases.map(\.rawValue))
        let kindValues = Set(WorkStateKind.allCases.map(\.rawValue))
        let transitionValues = Set(WorkStateTransitionKind.allCases.map(\.rawValue))
        let reviewValues = Set(WorkStateTransitionReviewStatus.allCases.map(\.rawValue))
        let relationKindValues = Set(WorkStateRelationKind.allCases.map(\.rawValue))

        for row in rows {
            for key in row.keys {
                XCTAssertTrue(allowedKeys.contains(Self.normalizedKey(key)), "unexpected stored field: \(key)")
            }

            if let evidence = row["evidence"] as? [String: Any] {
                for key in evidence.keys {
                    XCTAssertTrue(
                        allowedEvidenceKeys.contains(Self.normalizedKey(key)),
                        "unexpected evidence field: \(key) — a pointer must never grow a quote"
                    )
                }
            }

            for relation in (row["relations"] as? [[String: Any]]) ?? [] {
                for key in relation.keys {
                    XCTAssertTrue(
                        allowedRelationKeys.contains(Self.normalizedKey(key)),
                        "unexpected relation field: \(key)"
                    )
                }
                XCTAssertTrue(relationKindValues.contains((relation["kind"] as? String) ?? ""))
            }

            for reason in (row["reasons"] as? [String]) ?? [] {
                XCTAssertTrue(reasonValues.contains(reason), "\(reason) is not a declared reason")
            }
            XCTAssertTrue(basisValues.contains((row["basis"] as? String) ?? ""))
            XCTAssertTrue(kindValues.contains((row["workStateKind"] as? String) ?? ""))
            XCTAssertTrue(transitionValues.contains((row["transitionKind"] as? String) ?? ""))
            XCTAssertTrue(reviewValues.contains((row["reviewStatus"] as? String) ?? ""))
        }

        // The enums themselves are closed: a reason is chosen from a list a reviewer can read in
        // one place, not composed at the call site.
        XCTAssertEqual(
            Set(WorkStateTransitionReason.allCases.map(\.rawValue)).count,
            WorkStateTransitionReason.allCases.count
        )
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "")
    }

    // MARK: - Manual Continuity Brief contract

    func testAStoredResultExplainsItselfWithoutRerunningTheEngine() async throws {
        let url = fileURL()
        let input = Fixtures.representativeInput()
        let generated = WorkStateTransitionEngine.generate(input, now: Fixtures.generatedAt)
        WorkStateTransitionContract.assertInvariants(generated, for: input)

        // A brief that could only explain some of the six would be a brief with holes in it.
        XCTAssertEqual(
            Set(generated.proposals.map(\.transitionKind)),
            Set(WorkStateTransitionKind.allCases)
        )

        let writer = JSONWorkStateTransitionRepository(fileURL: url)
        try await writer.upsert(generated.proposals)

        // The brief runs later, from the store, with no engine in the picture.
        let reader = JSONWorkStateTransitionRepository(fileURL: url)
        let loaded = try await reader.proposals(forProject: input.projectID)
        XCTAssertEqual(loaded, generated.proposals)

        let priorIDs = Set(
            input.prior.decisions.map(\.id)
                + input.prior.actionItems.map(\.id)
                + input.prior.openQuestions.map(\.id)
                + input.prior.agendaItems.map(\.id)
        )
        let incomingIDs = Set(
            input.incoming.decisions.map(\.id)
                + input.incoming.actionItems.map(\.id)
                + input.incoming.openQuestions.map(\.id)
                + input.incoming.agendaItems.map(\.id)
        )

        for proposal in loaded {
            let label = "\(proposal.workStateKind.rawValue)/\(proposal.transitionKind.rawValue)"

            // 1-2. Which project, and which meeting produced the claim.
            XCTAssertEqual(proposal.projectID, input.projectID, label)
            XCTAssertEqual(proposal.sourceMeetingID, input.sourceMeetingID, label)

            // 3-4. What it is about, on both sides of the transition, resolvable back to real
            // objects — that is how the brief recovers the title and the quote to show.
            if let previous = proposal.previousStateID {
                XCTAssertTrue(priorIDs.contains(previous), "\(label): predecessor is unresolvable")
            }
            if let current = proposal.currentObjectID {
                XCTAssertTrue(incomingIDs.contains(current), "\(label): new object is unresolvable")
            }

            // 5-6. The classification and the structural fact behind it.
            XCTAssertTrue(WorkStateTransitionMatrix.supports(proposal.transitionKind, for: proposal.workStateKind), label)
            XCTAssertTrue(WorkStateTransitionBasis.allCases.contains(proposal.basis), label)

            // 7-8. What the user is being asked, and where the review stands.
            XCTAssertEqual(proposal.reviewStatus, .pendingReview, label)
            if proposal.requiresConfirmation {
                XCTAssertFalse(
                    proposal.transitionKind == .new,
                    "\(label): a brand-new item is never a change to confirm"
                )
            }

            // 9. Stable identity, so the same row is recognised on the next run.
            XCTAssertFalse(proposal.dedupKey.isEmpty, label)
            XCTAssertEqual(
                proposal.id,
                WorkStateTransitionProposal.deterministicID(forDedupKey: proposal.dedupKey),
                label
            )
        }

        // Now the named rows, so the test states what each explanation actually says.
        let newDecision = try XCTUnwrap(loaded.first { $0.workStateKind == .decision && $0.transitionKind == .new })
        XCTAssertNil(newDecision.previousStateID)
        XCTAssertEqual(newDecision.currentObjectID, Representative.newDecision)
        XCTAssertEqual(newDecision.basis, .noPriorCandidate)
        XCTAssertEqual(newDecision.reasons, [])
        XCTAssertFalse(newDecision.requiresConfirmation)
        XCTAssertEqual(newDecision.evidence?.meetingID, Fixtures.sourceMeetingID)

        let same = try XCTUnwrap(loaded.first { $0.transitionKind == .same })
        XCTAssertEqual(same.workStateKind, .actionItem)
        XCTAssertEqual(same.previousStateID, Representative.priorMatchedActionItem)
        XCTAssertEqual(same.currentObjectID, Representative.incomingMatchedActionItem)
        XCTAssertEqual(same.basis, .exactNormalizedTextMatch)

        let completed = try XCTUnwrap(loaded.first { $0.transitionKind == .completed })
        XCTAssertEqual(completed.previousStateID, Representative.priorMatchedActionItem)
        XCTAssertEqual(completed.currentObjectID, Representative.incomingMatchedActionItem)
        XCTAssertEqual(completed.basis, .structuredProgressSignal)
        XCTAssertTrue(completed.requiresConfirmation)
        XCTAssertEqual(completed.reasons, [.stateChangeRequiresApproval])
        XCTAssertEqual(completed.evidence?.transcriptSegmentID, Fixtures.signalSegmentID)

        let delayed = try XCTUnwrap(loaded.first { $0.transitionKind == .delayed })
        XCTAssertEqual(delayed.previousStateID, Representative.priorOverdueActionItem)
        XCTAssertNil(delayed.currentObjectID)
        XCTAssertEqual(delayed.basis, .overdueApprovedDueDate)
        XCTAssertNil(delayed.evidence, "an overdue date is a fact about stored state, not a quote")

        let changed = try XCTUnwrap(loaded.first { $0.transitionKind == .changed })
        XCTAssertEqual(changed.workStateKind, .openQuestion)
        XCTAssertEqual(changed.previousStateID, Representative.priorRevisedQuestion)
        XCTAssertEqual(changed.currentObjectID, Representative.incomingRevisedQuestion)
        XCTAssertEqual(changed.basis, .nearTextMatch)
        XCTAssertEqual(changed.reasons, [.similarityOnly])

        let resolved = try XCTUnwrap(loaded.first { $0.transitionKind == .resolved })
        XCTAssertEqual(resolved.previousStateID, Representative.priorResolvedQuestion)
        XCTAssertEqual(resolved.currentObjectID, Representative.newDecision)
        XCTAssertEqual(resolved.basis, .structuredResolutionLink)
        XCTAssertEqual(
            resolved.relations,
            [
                WorkStateTransitionRelation(
                    kind: .resolvedBy,
                    relatedKind: .decision,
                    relatedObjectID: Representative.newDecision
                )
            ]
        )

        // 10. Relations survive storage, on every row they were attached to — the brief has to be
        // able to say "this task exists because of that decision" for the completion row too.
        let derived = WorkStateTransitionRelation(
            kind: .derivedFrom,
            relatedKind: .decision,
            relatedObjectID: Representative.newDecision
        )
        XCTAssertTrue(same.relations.contains(derived))
        XCTAssertTrue(completed.relations.contains(derived))
    }

    // MARK: - Cross-project isolation at the repository

    func testTheRepositoryNeverReturnsAnotherProjectsProposals() async throws {
        let url = fileURL()

        let inputA = Fixtures.representativeInput()
        let generatedA = WorkStateTransitionEngine.generate(inputA, now: Fixtures.generatedAt)

        let inputB = Fixtures.input(
            inProject: Fixtures.otherProjectID,
            incoming: Fixtures.incoming(
                decisions: [
                    Fixtures.incomingDecision(
                        id: Fixtures.uuid(400),
                        statement: Fixtures.decisionStatement,
                        inProject: Fixtures.otherProjectID
                    )
                ],
                actionItems: [
                    Fixtures.incomingActionItem(
                        id: Fixtures.uuid(401),
                        title: Fixtures.actionItemTitle,
                        inProject: Fixtures.otherProjectID
                    )
                ]
            )
        )
        let generatedB = WorkStateTransitionEngine.generate(inputB, now: Fixtures.generatedAt)

        XCTAssertFalse(generatedA.proposals.isEmpty)
        XCTAssertFalse(generatedB.proposals.isEmpty)

        let repository = JSONWorkStateTransitionRepository(fileURL: url)
        try await repository.upsert(generatedA.proposals)
        try await repository.upsert(generatedB.proposals)

        let rowsForA = try await repository.proposals(forProject: Fixtures.projectID)
        let rowsForB = try await repository.proposals(forProject: Fixtures.otherProjectID)

        XCTAssertEqual(rowsForA, generatedA.proposals)
        XCTAssertEqual(rowsForB, generatedB.proposals)
        XCTAssertTrue(rowsForA.allSatisfy { $0.projectID == Fixtures.projectID })
        XCTAssertTrue(rowsForB.allSatisfy { $0.projectID == Fixtures.otherProjectID })
        XCTAssertTrue(Set(rowsForA.map(\.id)).isDisjoint(with: Set(rowsForB.map(\.id))))

        // Both projects share one file, so `allProposals` must still see everything — the
        // filtering is a query, not a partitioned store that could silently drop rows.
        let all = try await repository.allProposals()
        XCTAssertEqual(all.count, generatedA.proposals.count + generatedB.proposals.count)
        XCTAssertEqual(all.map(\.dedupKey), all.map(\.dedupKey).sorted())

        // A project with nothing stored gets nothing, rather than everything.
        let unknown = try await repository.proposals(forProject: Fixtures.uuid(1_999))
        XCTAssertEqual(unknown, [])

        // Survives a restart: the filter is applied on read, not held in memory.
        let reopened = JSONWorkStateTransitionRepository(fileURL: url)
        let rowsForAAfterRestart = try await reopened.proposals(forProject: Fixtures.projectID)
        XCTAssertEqual(rowsForAAfterRestart, generatedA.proposals)
    }
}
