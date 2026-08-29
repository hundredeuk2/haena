import XCTest
@testable import HAENA

/// Exercises the harness end to end over synthetic cases: the offline stub's six proposals go in,
/// and one artifact whose `raw` / `mapped` / `rejected` sections account for every one of them comes
/// out — with no score anywhere in it.
final class BenchmarkRunnerTests: XCTestCase {
    private enum TestFailure: Error {
        case notProduced
    }

    private static let executedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// The ordinals `BenchmarkStubExtractor` produces, in the runner's fixed
    /// decisions -> action items -> open questions -> agenda items order.
    private enum StubOrdinal {
        static let groundedDecision = 0
        static let emptyDecision = 1
        static let groundedActionItem = 2
        static let outOfRangeConfidence = 3
        static let unknownSegmentQuestion = 4
        static let ungroundedQuoteAgendaItem = 5
        static let total = 6
    }

    // MARK: - Helpers

    private func runStub(
        _ preparedCase: BenchmarkPreparedCase,
        executedAt: Date = BenchmarkRunnerTests.executedAt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> PredictionArtifact {
        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { executedAt })
        let outcome = await runner.run(preparedCase, options: BenchmarkFixtures.runOptions)
        return try produced(outcome, file: file, line: line)
    }

    private func produced(
        _ outcome: BenchmarkCaseOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PredictionArtifact {
        guard case .produced(let artifact) = outcome else {
            XCTFail("expected the case to produce an artifact", file: file, line: line)
            throw TestFailure.notProduced
        }
        return artifact
    }

    private func mapperRejections(_ artifact: PredictionArtifact) -> [BenchmarkRejectionRecord] {
        artifact.rejected.filter { $0.stage == .mapper }
    }

    private func rejection(_ artifact: PredictionArtifact, ordinal: Int) -> BenchmarkRejectionRecord? {
        artifact.rejected.first { $0.proposalOrdinal == ordinal }
    }

    // MARK: - raw / mapped / rejected are separate records

    func testStubRunFillsRawMappedAndRejectedSeparately() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        XCTAssertEqual(artifact.raw.count, StubOrdinal.total)
        XCTAssertEqual(artifact.mapped.count, 2, "two of the stub's six proposals are groundable")
        XCTAssertEqual(artifact.rejected.count, 4)
        XCTAssertTrue(
            artifact.rejected.allSatisfy { $0.stage == .mapper },
            "a case with no unknown speakers has no input-stage rejections"
        )

        // Every proposal lands in exactly one of the two outcome sections, and the ordinals say
        // which is which — that is the whole point of mapping one proposal at a time.
        let mappedOrdinals = Set(artifact.mapped.map(\.ordinal))
        let rejectedOrdinals = Set(artifact.rejected.compactMap(\.proposalOrdinal))
        XCTAssertTrue(mappedOrdinals.isDisjoint(with: rejectedOrdinals))
        XCTAssertEqual(mappedOrdinals.union(rejectedOrdinals), Set(0..<StubOrdinal.total))
        XCTAssertEqual(artifact.raw.map(\.ordinal), Array(0..<StubOrdinal.total))
    }

    func testRawProposalsAreOrderedByKindThenModelOrder() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        XCTAssertEqual(
            artifact.raw.map(\.kind),
            [.decision, .decision, .actionItem, .actionItem, .openQuestion, .agendaItem]
        )
    }

    // MARK: - Each stubbed rejection path keeps its reason

    func testEachStubbedProposalKeepsItsExpectedRejectionReason() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.emptyDecision)?.reason, .missingRequiredField)
        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.emptyDecision)?.kind, .decision)

        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.outOfRangeConfidence)?.reason, .confidenceOutOfRange)
        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.outOfRangeConfidence)?.kind, .actionItem)

        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.unknownSegmentQuestion)?.reason, .evidenceNotFound)
        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.unknownSegmentQuestion)?.kind, .openQuestion)

        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.ungroundedQuoteAgendaItem)?.reason, .quoteNotInTranscript)
        XCTAssertEqual(rejection(artifact, ordinal: StubOrdinal.ungroundedQuoteAgendaItem)?.kind, .agendaItem)

        XCTAssertNil(rejection(artifact, ordinal: StubOrdinal.groundedDecision))
        XCTAssertNil(rejection(artifact, ordinal: StubOrdinal.groundedActionItem))
    }

    func testRejectedProposalsSurviveVerbatimInTheRawSection() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        // `raw` is the only place a rejected proposal's content survives, so it must not be
        // trimmed, repaired, or normalised on the way in.
        XCTAssertEqual(artifact.raw[StubOrdinal.emptyDecision].text, "")
        XCTAssertEqual(artifact.raw[StubOrdinal.outOfRangeConfidence].confidence, 1.5)
        XCTAssertEqual(
            artifact.raw[StubOrdinal.unknownSegmentQuestion].citedSegmentID,
            BenchmarkStubExtractor.absentSegmentID
        )
        XCTAssertNil(
            artifact.raw[StubOrdinal.unknownSegmentQuestion].citedUtteranceID,
            "a segment id that resolves to nothing must reverse-map to nil, not to a guess"
        )
        XCTAssertEqual(
            artifact.raw[StubOrdinal.ungroundedQuoteAgendaItem].quote,
            BenchmarkStubExtractor.absentQuote
        )
    }

    func testAcceptedProposalsCarryCorpusBackReferences() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        XCTAssertEqual(artifact.mapped.map(\.ordinal), [StubOrdinal.groundedDecision, StubOrdinal.groundedActionItem])
        XCTAssertEqual(artifact.mapped[0].kind, .decision)
        XCTAssertEqual(artifact.mapped[0].status, "proposed")
        XCTAssertEqual(artifact.mapped[1].kind, .actionItem)
        XCTAssertNotNil(artifact.mapped[0].evidenceUtteranceID, "an accepted proposal must name the corpus utterance it came from")
        XCTAssertNotNil(artifact.mapped[1].evidenceUtteranceID)

        // The stub makes an evidence-speaker commitment. Raw provenance stays verbatim while the
        // mapped section records the finite resolution and app-owned participant separately.
        let raw = artifact.raw[StubOrdinal.groundedActionItem]
        XCTAssertEqual(raw.assigneeAttributionBasis, .speakerCommitment)
        XCTAssertNil(raw.assigneeReference)
        XCTAssertNotNil(raw.assigneeSpeakerLabel)
        XCTAssertNotNil(artifact.mapped[1].assigneeParticipantID)
        XCTAssertEqual(artifact.mapped[1].assigneeSpeakerLabel, raw.assigneeSpeakerLabel)
        XCTAssertEqual(artifact.mapped[1].assigneeAttributionResolution, .resolved)
    }

    func testProposalIdentityMatchesTheProductMapperProviderLocalKeyContract() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let extractor = BenchmarkStubExtractor()
        let raw = try await extractor.extract(from: prepared.extractionInput)
        let expected = WorkStateProposalMapper.map(
            raw,
            meeting: prepared.meeting,
            now: BenchmarkRunner.mappingDate
        ).providerLocalKeyToDomainID
        let artifact = try await runStub(prepared)

        XCTAssertEqual(artifact.mapped[0].id, expected["decision_1"])
        XCTAssertEqual(artifact.mapped[1].id, expected["action_1"])
        XCTAssertNotEqual(artifact.mapped[0].id, artifact.mapped[1].id)
    }

    func testOfflineExtractorsUseUniqueBoundedKeysAndEmitNoContinuitySignals() async throws {
        let input = try BenchmarkFixtures.prepared().extractionInput
        let results = [
            try await BenchmarkStubExtractor().extract(from: input),
            try await DeterministicWorkStateExtractor(now: { Self.executedAt }).extract(from: input)
        ]

        for result in results {
            let keys = result.decisions.map(\.providerLocalKey)
                + result.actionItems.map(\.providerLocalKey)
                + result.openQuestions.map(\.providerLocalKey)
                + result.nextAgendaItems.map(\.providerLocalKey)

            XCTAssertEqual(Set(keys).count, keys.count)
            XCTAssertTrue(keys.allSatisfy { !$0.isEmpty && $0.count <= 64 })
            XCTAssertTrue(keys.allSatisfy { key in
                key.unicodeScalars.allSatisfy {
                    CharacterSet.lowercaseLetters.contains($0)
                        || CharacterSet.decimalDigits.contains($0)
                        || $0 == "_"
                }
            })
            XCTAssertTrue(keys.allSatisfy { UUID(uuidString: $0) == nil })
            XCTAssertTrue(result.progressSignals.isEmpty)
            XCTAssertTrue(result.openQuestionResolutionLinks.isEmpty)
            XCTAssertTrue(result.decisionDerivedActionItemLinks.isEmpty)
        }
    }

    func testDuplicateProviderKeysRemainBaseRejectionsWithoutChangingTheArtifactSchema() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let excerpt = prepared.extractionInput.excerpts[0]
        let evidence = ProposedEvidence(
            segmentID: excerpt.segmentID.uuidString,
            quote: "다음 주까지"
        )
        let result = WorkStateExtractionResult(
            decisions: [
                ProposedDecision(
                    providerLocalKey: "duplicate_1",
                    statement: "중복 key 결정",
                    rationale: nil,
                    confidence: 0.8,
                    evidence: evidence
                )
            ],
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "duplicate_1",
                    title: "중복 key 실행 항목",
                    details: nil,
                    assigneeAttribution: ProposedAssigneeAttribution(
                        basis: .unspecified,
                        reference: nil,
                        speakerLabel: nil
                    ),
                    dueDate: nil,
                    confidence: 0.8,
                    evidence: evidence
                )
            ],
            metadata: ExtractionFixtures.metadata
        )
        let runner = BenchmarkRunner(
            extractor: StubWorkStateExtractor(.success(result)),
            now: { Self.executedAt }
        )

        let artifact = try produced(await runner.run(prepared, options: BenchmarkFixtures.runOptions))

        XCTAssertEqual(artifact.artifactSchemaVersion, "prediction-v0.2")
        XCTAssertEqual(artifact.raw.count, 2)
        XCTAssertTrue(artifact.mapped.isEmpty)
        XCTAssertEqual(mapperRejections(artifact).count, 2)
        XCTAssertTrue(mapperRejections(artifact).allSatisfy { $0.reason == .mapperValidationFailed })
        XCTAssertFalse(artifact.rejected.contains { $0.reason == .unsupportedProposalType })
    }

    // MARK: - Nothing disappears between raw and mapped

    func testEveryRawProposalIsEitherMappedOrRejected() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        XCTAssertEqual(artifact.raw.count, artifact.mapped.count + mapperRejections(artifact).count)
    }

    func testInputStageRejectionsDoNotDisturbTheMapperAccounting() async throws {
        let prepared = try BenchmarkFixtures.prepared(includeUnknownSpeaker: true)
        let artifact = try await runStub(prepared)

        let inputRecords = artifact.rejected.filter { $0.stage == .input }
        XCTAssertFalse(inputRecords.isEmpty, "the fixture is built with an unattributable utterance")
        XCTAssertTrue(inputRecords.allSatisfy { $0.reason == .unknownSpeaker })
        XCTAssertEqual(inputRecords.compactMap(\.utteranceID).sorted(), prepared.unknownSpeakerUtteranceIDs.sorted())
        XCTAssertTrue(inputRecords.allSatisfy { $0.proposalOrdinal == nil })

        XCTAssertEqual(artifact.raw.count, artifact.mapped.count + mapperRejections(artifact).count)
        XCTAssertEqual(artifact.inputSummary.unknownSpeakerUtteranceCount, prepared.unknownSpeakerUtteranceIDs.count)
    }

    // MARK: - Scoring

    func testGoldPendingCaseIsRecordedAsUnscored() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let artifact = try await runStub(prepared)

        XCTAssertEqual(artifact.scoring.status, .unscored)
        XCTAssertEqual(
            artifact.scoring.reason,
            prepared.isGoldPending ? "human_review_pending" : "scoring_not_implemented"
        )
    }

    func testArtifactCarriesNoScoreLikeField() async throws {
        let artifact = try await runStub(BenchmarkFixtures.prepared())

        let data = try PredictionArtifact.encoder.encode(artifact)
        let keys = Self.allKeys(in: try JSONSerialization.jsonObject(with: data))

        XCTAssertTrue(keys.contains("scoring"), "guards against a vacuous assertion below")
        for forbidden in ["precision", "recall", "accuracy", "score", "f1"] {
            XCTAssertTrue(
                keys.allSatisfy { !$0.lowercased().contains(forbidden) },
                "no artifact field may be named after a metric — found one containing '\(forbidden)'"
            )
        }
        // Checked on keys rather than on the whole document on purpose: the legitimate *value*
        // "unscored" contains "score", and a sha256 hash or a UUID routinely contains "f1".
    }

    // MARK: - Reproducibility

    func testTwoRunsOfTheSameInputDifferOnlyInExecutedAt() async throws {
        let prepared = try BenchmarkFixtures.prepared()

        let first = try await runStub(prepared, executedAt: Date(timeIntervalSince1970: 1))
        let second = try await runStub(prepared, executedAt: Date(timeIntervalSince1970: 2))

        XCTAssertNotEqual(first.executedAt, second.executedAt)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.reproducibleFields, second.reproducibleFields)

        let encoder = PredictionArtifact.encoder
        XCTAssertEqual(
            try encoder.encode(first.reproducibleFields),
            try encoder.encode(second.reproducibleFields),
            "reproducible artifacts must be byte-identical, not merely Equatable"
        )
    }

    // MARK: - Failure handling

    func testExtractorFailureProducesNoArtifactAndIsCounted() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let runner = BenchmarkRunner(
            extractor: StubWorkStateExtractor(.failure(.networkUnavailable)),
            now: { Self.executedAt }
        )

        let (report, outcomes) = await runner.run([prepared], options: BenchmarkFixtures.runOptions)

        guard let outcome = outcomes.first, case .failed(let caseID, let failure) = outcome else {
            XCTFail("a throwing extractor must yield a failed outcome, not an empty artifact")
            return
        }
        XCTAssertEqual(caseID, prepared.caseID)
        XCTAssertEqual(failure, .extractorFailed)
        XCTAssertEqual(report.producedCount, 0)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.caseIDs, [prepared.caseID])
    }

    func testEmptyExtractionResultProducesAnEmptyButValidArtifact() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let runner = BenchmarkRunner(
            extractor: StubWorkStateExtractor(.success(ExtractionFixtures.emptyResult())),
            now: { Self.executedAt }
        )

        let artifact = try produced(await runner.run(prepared, options: BenchmarkFixtures.runOptions))

        XCTAssertTrue(artifact.raw.isEmpty)
        XCTAssertTrue(artifact.mapped.isEmpty)
        XCTAssertTrue(artifact.rejected.isEmpty)
        XCTAssertEqual(artifact.scoring.status, .unscored)
    }

    // MARK: - Report

    func testReportCountsAggregateTheArtifacts() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.executedAt })

        let (report, outcomes) = await runner.run([prepared], options: BenchmarkFixtures.runOptions)
        let artifact = try produced(outcomes[0])

        XCTAssertEqual(report.benchmark, BenchmarkFixtures.runOptions.benchmark)
        XCTAssertEqual(report.runMode, BenchmarkFixtures.runOptions.provider.runMode)
        XCTAssertEqual(report.caseCount, 1)
        XCTAssertEqual(report.producedCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.rawProposalCount, artifact.raw.count)
        XCTAssertEqual(report.mappedProposalCount, artifact.mapped.count)
        XCTAssertEqual(report.rejectedProposalCount, artifact.rejected.count)
        XCTAssertEqual(report.unscoredCount, 1)
    }

    func testReportAccountsForCasesThatNeverReachedTheExtractor() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.executedAt })
        let (report, _) = await runner.run([prepared], options: BenchmarkFixtures.runOptions)

        let merged = report.including(failedCaseIDs: ["SYN-404"])

        XCTAssertEqual(merged.caseCount, report.caseCount + 1)
        XCTAssertEqual(merged.failedCount, report.failedCount + 1)
        XCTAssertEqual(merged.producedCount, report.producedCount)
        XCTAssertEqual(merged.caseIDs, report.caseIDs + ["SYN-404"])
        XCTAssertEqual(report.including(failedCaseIDs: []), report)
    }

    // MARK: - Case selection

    func testRunningOneCaseIDProducesOnlyThatCasesArtifact() async throws {
        let root = try BenchmarkFixtures.writeTemporaryDataset(
            developmentCaseIDs: ["SYN-001", "SYN-002"],
            sealedHoldoutCaseIDs: []
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BenchmarkCaseStore(datasetRoot: root)
        let preparedCases = try store.entries(caseIDs: ["SYN-002"]).map { try store.prepared($0) }

        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.executedAt })
        let (report, outcomes) = await runner.run(preparedCases, options: BenchmarkFixtures.runOptions)

        XCTAssertEqual(report.caseCount, 1)
        XCTAssertEqual(report.caseIDs, ["SYN-002"])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try produced(outcomes[0]).caseID, "SYN-002")
    }

    func testArtifactsAreEmittedInTheOrderTheCasesWereGiven() async throws {
        let root = try BenchmarkFixtures.writeTemporaryDataset(
            developmentCaseIDs: ["SYN-001", "SYN-002"],
            sealedHoldoutCaseIDs: []
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BenchmarkCaseStore(datasetRoot: root)
        let preparedCases = try store.entries(caseIDs: ["SYN-002", "SYN-001"]).map { try store.prepared($0) }

        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.executedAt })
        let (report, _) = await runner.run(preparedCases, options: BenchmarkFixtures.runOptions)

        XCTAssertEqual(report.caseIDs, ["SYN-002", "SYN-001"])
    }

    // MARK: - JSON helpers

    /// Every key appearing anywhere in a decoded JSON document.
    private static func allKeys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { keys, entry in
                keys.formUnion(allKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { keys, element in
                keys.formUnion(allKeys(in: element))
            }
        }
        return []
    }
}
