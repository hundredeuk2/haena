import XCTest
@testable import HAENA

final class BenchmarkArtifactSchemaTests: XCTestCase {

    // MARK: - Identity of the file format

    func testEncodedArtifactAnnouncesItsSchemaAndKind() throws {
        let object = try encodedObject(artifact())

        XCTAssertEqual(object["artifact_schema_version"] as? String, "prediction-v0.2")
        XCTAssertEqual(object["artifact_kind"] as? String, "haena_prediction")
        XCTAssertEqual(PredictionArtifact.schemaVersion, "prediction-v0.2")
        XCTAssertEqual(PredictionArtifact.artifactKind, "haena_prediction")
    }

    /// A prediction file must never be mistakable for a `model_suggestion` draft or for human gold,
    /// because both of those live in the same dataset tree and one of them is the thing this task
    /// is forbidden to treat as a target.
    func testEncodedArtifactMentionsNeitherDraftsNorGold() throws {
        let json = try encodedString(artifact())

        XCTAssertFalse(json.contains("model_suggestion"))
        XCTAssertFalse(json.contains("\"gold\""))
        XCTAssertFalse(json.contains("gold_"))
    }

    /// The gold this would be measured against does not exist yet, so any number that reads like a
    /// result would be a fabricated one. Keys are matched in quoted form: a bare `f1` or `score`
    /// substring occurs by chance inside hex digests and inside the word `unscored`.
    func testEncodedArtifactCarriesNoMeasurement() throws {
        let json = try encodedString(artifact())

        for forbidden in ["\"precision\"", "\"recall\"", "\"accuracy\"", "\"f1\"", "\"score\""] {
            XCTAssertFalse(json.contains(forbidden), "artifact must not contain \(forbidden)")
        }

        let object = try encodedObject(artifact())
        let scoring = try XCTUnwrap(object["scoring"] as? [String: Any])
        XCTAssertEqual(scoring["status"] as? String, "unscored")
        XCTAssertEqual(scoring["reason"] as? String, "human_review_pending")
        XCTAssertEqual(Set(scoring.keys), ["status", "reason"])
    }

    // MARK: - Key shape

    func testTopLevelKeysAreExactlyTheContractedSnakeCaseSet() throws {
        let object = try encodedObject(artifact())

        XCTAssertEqual(
            Set(object.keys),
            [
                "artifact_schema_version", "artifact_kind", "benchmark", "case_id", "split",
                "dataset_schema_version", "source_case_hash", "extraction_schema_version",
                "prompt_revision", "git_revision", "provider", "model_id", "run_mode",
                "executed_at", "scoring", "input_summary", "raw", "mapped", "rejected"
            ]
        )
        XCTAssertTrue(
            object.keys.allSatisfy { $0 == $0.lowercased() },
            "camelCase would leak Swift property names into the file format"
        )
    }

    func testNestedRecordKeysAreSnakeCaseToo() throws {
        let object = try encodedObject(artifact())

        let summary = try XCTUnwrap(object["input_summary"] as? [String: Any])
        XCTAssertEqual(
            Set(summary.keys),
            ["utterance_count", "participant_count", "speaker_labels", "unknown_speaker_utterance_count"]
        )

        let raw = try XCTUnwrap((object["raw"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(raw.keys),
            [
                "ordinal", "kind", "text", "supporting_text", "assignee_attribution_basis",
                "assignee_reference", "assignee_speaker_label", "due_date", "confidence",
                "cited_segment_id", "cited_utterance_id", "quote"
            ]
        )

        let mapped = try XCTUnwrap((object["mapped"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(mapped.keys),
            [
                "ordinal", "kind", "id", "text", "assignee_participant_id", "assignee_speaker_label",
                "assignee_attribution_resolution", "due_date", "confidence", "evidence_segment_id",
                "evidence_utterance_id", "evidence_quote", "status"
            ]
        )

        let rejected = try XCTUnwrap(object["rejected"] as? [[String: Any]])
        XCTAssertEqual(rejected.count, 2)
        XCTAssertEqual(rejected[0]["stage"] as? String, "input")
        XCTAssertEqual(rejected[0]["reason"] as? String, "unknown_speaker")
        XCTAssertEqual(rejected[0]["utterance_id"] as? String, "SYN-001.1.3")
        XCTAssertEqual(rejected[1]["stage"] as? String, "mapper")
        XCTAssertEqual(rejected[1]["reason"] as? String, "evidence_not_found")
        XCTAssertEqual(rejected[1]["kind"] as? String, "open_question")
    }

    func testProposalKindRawValuesAreTheContractedStrings() {
        XCTAssertEqual(
            BenchmarkProposalKind.allCasesForTest.map(\.rawValue),
            ["decision", "action_item", "open_question", "agenda_item"]
        )
    }

    func testAttributionRawValuesAreFiniteAndStable() {
        XCTAssertEqual(
            AssigneeAttributionBasis.allCases.map(\.rawValue),
            ["explicit_name", "self_reference", "speaker_commitment", "team_or_role", "unspecified"]
        )
        XCTAssertEqual(
            AssigneeAttributionResolution.allCases.map(\.rawValue),
            [
                "resolved", "no_participant_match", "ambiguous_participant_match",
                "missing_evidence_speaker", "evidence_speaker_not_participant",
                "speaker_label_mismatch", "non_individual", "unspecified", "invalid_attribution"
            ]
        )
    }

    func testPerCaseArtifactPreservesRawAttributionProvenance() throws {
        let object = try encodedObject(artifact())
        let raw = try XCTUnwrap((object["raw"] as? [[String: Any]])?.first)
        let mapped = try XCTUnwrap((object["mapped"] as? [[String: Any]])?.first)

        XCTAssertEqual(raw["assignee_attribution_basis"] as? String, "self_reference")
        XCTAssertEqual(raw["assignee_reference"] as? String, "제가")
        XCTAssertEqual(raw["assignee_speaker_label"] as? String, "B")
        XCTAssertEqual(mapped["assignee_attribution_resolution"] as? String, "resolved")
    }

    // MARK: - Byte-level stability

    func testTopLevelKeysAreWrittenInSortedOrderSoTwoRunsCanBeDiffed() throws {
        let json = try encodedString(artifact())

        let topLevelKeys: [String] = json.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  \"") else { return nil }
            let afterQuote = line.dropFirst(3)
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[..<end])
        }

        XCTAssertEqual(topLevelKeys.count, 19)
        XCTAssertEqual(topLevelKeys, topLevelKeys.sorted())
    }

    func testDatesAreEncodedAsISO8601() throws {
        let object = try encodedObject(artifact())

        XCTAssertEqual(object["executed_at"] as? String, "2023-11-14T22:13:20Z")

        let raw = try XCTUnwrap((object["raw"] as? [[String: Any]])?.first)
        let dueDate = try XCTUnwrap(raw["due_date"] as? String)
        XCTAssertTrue(dueDate.hasSuffix("Z"))
        XCTAssertEqual(dueDate.count, 20, "yyyy-MM-ddTHH:mm:ssZ")
    }

    func testEncodingIsStableAcrossCalls() throws {
        XCTAssertEqual(try encodedString(artifact()), try encodedString(artifact()))
    }

    func testArtifactSurvivesARoundTrip() throws {
        let original = artifact()

        let data = try PredictionArtifact.encoder.encode(original)
        let decoded = try PredictionArtifact.decoder.decode(PredictionArtifact.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Reproducibility comparison

    func testReproducibleFieldsIgnoresExecutedAtAndNothingElse() {
        let first = artifact(executedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = artifact(executedAt: Date(timeIntervalSince1970: 1_900_000_000))

        XCTAssertNotEqual(first, second, "the artifacts themselves differ")
        XCTAssertEqual(first.reproducibleFields, second.reproducibleFields)
        XCTAssertEqual(
            first.reproducibleFields.executedAt,
            PredictionArtifact.reproducibilityInstant
        )
    }

    func testReproducibleFieldsStillSeesEveryOtherDifference() {
        let baseline = artifact()

        XCTAssertNotEqual(
            baseline.reproducibleFields,
            artifact(gitRevision: "deadbee").reproducibleFields
        )
        XCTAssertNotEqual(
            baseline.reproducibleFields,
            artifact(sourceCaseHash: "sha256:00").reproducibleFields
        )
        XCTAssertNotEqual(
            baseline.reproducibleFields,
            artifact(rawText: "다른 결정").reproducibleFields
        )
    }

    // MARK: - Fixtures

    private func encodedString(_ artifact: PredictionArtifact) throws -> String {
        String(decoding: try PredictionArtifact.encoder.encode(artifact), as: UTF8.self)
    }

    private func encodedObject(_ artifact: PredictionArtifact) throws -> [String: Any] {
        let data = try PredictionArtifact.encoder.encode(artifact)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func artifact(
        executedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        gitRevision: String = "abc1234",
        sourceCaseHash: String = "sha256:0f1e2d3c",
        rawText: String = "다음 주까지 초안을 정리한다"
    ) -> PredictionArtifact {
        let segmentID = BenchmarkIdentity.segmentID(
            benchmark: "meeting-execution-v0",
            caseID: "SYN-001",
            utteranceID: "SYN-001.1.1"
        )
        let proposalID = BenchmarkIdentity.proposalID(
            benchmark: "meeting-execution-v0",
            caseID: "SYN-001",
            ordinal: 0
        )

        return PredictionArtifact(
            benchmark: "meeting-execution-v0",
            caseID: "SYN-001",
            split: .development,
            datasetSchemaVersion: "haena-benchmark-v0.1",
            sourceCaseHash: sourceCaseHash,
            extractionSchemaVersion: "work_state_extraction",
            promptRevision: "benchmark-stub-v1",
            gitRevision: gitRevision,
            provider: "stub",
            modelID: "benchmark-stub-v1",
            runMode: "offline_stub",
            executedAt: executedAt,
            scoring: BenchmarkScoring(reason: "human_review_pending"),
            inputSummary: PredictionArtifact.InputSummary(
                utteranceCount: 3,
                participantCount: 2,
                speakerLabels: ["A", "B"],
                unknownSpeakerUtteranceCount: 1
            ),
            raw: [
                BenchmarkRawProposal(
                    ordinal: 0,
                    kind: .actionItem,
                    text: rawText,
                    supportingText: "회의에서 합의됨",
                    assigneeAttributionBasis: .selfReference,
                    assigneeReference: "제가",
                    assigneeSpeakerLabel: "B",
                    dueDate: Date(timeIntervalSince1970: 1_800_000_000),
                    confidence: 0.8,
                    citedSegmentID: segmentID.uuidString,
                    citedUtteranceID: "SYN-001.1.1",
                    quote: "다음 주까지 초안을 정리하기로 했습니다."
                )
            ],
            mapped: [
                BenchmarkMappedProposal(
                    ordinal: 0,
                    kind: .actionItem,
                    id: proposalID,
                    text: rawText,
                    // Non-nil on purpose: the synthesized encoder omits a nil optional entirely,
                    // so a fixture full of nils could not assert the record's full key set.
                    assigneeParticipantID: BenchmarkIdentity.participantID(
                        benchmark: "meeting-execution-v0",
                        caseID: "SYN-001",
                        speaker: "B"
                    ),
                    assigneeSpeakerLabel: "B",
                    assigneeAttributionResolution: .resolved,
                    dueDate: Date(timeIntervalSince1970: 1_800_000_000),
                    confidence: 0.8,
                    evidenceSegmentID: segmentID,
                    evidenceUtteranceID: "SYN-001.1.1",
                    evidenceQuote: "다음 주까지 초안을 정리하기로 했습니다.",
                    status: "proposed"
                )
            ],
            rejected: [
                BenchmarkRejectionRecord(
                    stage: .input,
                    reason: .unknownSpeaker,
                    utteranceID: "SYN-001.1.3"
                ),
                BenchmarkRejectionRecord(
                    stage: .mapper,
                    kind: .openQuestion,
                    reason: .evidenceNotFound,
                    proposalOrdinal: 2,
                    citedSegmentID: "not-a-uuid",
                    citedUtteranceID: nil
                )
            ]
        )
    }
}

private extension BenchmarkProposalKind {
    /// Declaration order matters for the assertion above, and `CaseIterable` is not part of the
    /// contracted API for this enum, so the list is spelled out here rather than synthesized.
    static let allCasesForTest: [BenchmarkProposalKind] = [
        .decision, .actionItem, .openQuestion, .agendaItem
    ]
}
