import XCTest
@testable import HAENA

final class BenchmarkAdapterTests: XCTestCase {

    // MARK: - Speakers

    func testParticipantsComeFromSpeakerMappingValuesSortedByLabel() throws {
        let prepared = try BenchmarkFixtures.prepared()

        XCTAssertEqual(prepared.meeting.participants.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(prepared.meeting.participants.map(\.displayName), ["A", "B"])
        XCTAssertTrue(
            prepared.meeting.participants.allSatisfy { $0.linkedUserID == nil },
            "the corpus is anonymized; no participant may be linked to an account"
        )
        XCTAssertEqual(
            prepared.meeting.participants.map(\.id),
            ["A", "B"].map {
                BenchmarkIdentity.participantID(
                    benchmark: BenchmarkFixtures.benchmark,
                    caseID: "SYN-001",
                    speaker: $0
                )
            }
        )
    }

    /// Contract: a labelled speaker survives all the way from `speaker_mapping` through the
    /// participant list, the segment's `speakerID`, and the excerpt the extractor actually sees.
    func testSpeakerLabelsSurviveIntoSegmentsAndExtractionInput() throws {
        let prepared = try BenchmarkFixtures.prepared()
        let segments = prepared.meeting.transcriptSegments
        let participantIDByLabel = Dictionary(
            uniqueKeysWithValues: prepared.meeting.participants.map { ($0.speakerLabel ?? "", $0.id) }
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].speakerID, participantIDByLabel["A"])
        XCTAssertEqual(segments[1].speakerID, participantIDByLabel["B"])
        XCTAssertEqual(segments[2].speakerID, participantIDByLabel["A"])

        XCTAssertEqual(prepared.speakerLabelBySegmentID[segments[0].id], "A")
        XCTAssertEqual(prepared.speakerLabelBySegmentID[segments[1].id], "B")

        XCTAssertEqual(
            prepared.extractionInput.excerpts.map(\.speakerLabel),
            ["A", "B", "A"],
            "the extractor must be able to attribute a line without re-reading the corpus"
        )
        XCTAssertEqual(prepared.extractionInput.excerpts.map(\.segmentID), segments.map(\.id))
    }

    func testUnknownSpeakerLeavesTheSegmentUnattributedAndIsRecorded() throws {
        let prepared = try BenchmarkFixtures.prepared(includeUnknownSpeaker: true)
        let unattributed = prepared.meeting.transcriptSegments[2]

        XCTAssertNil(unattributed.speakerID, "an unmapped label must not be attributed to anyone")
        XCTAssertEqual(unattributed.sourceSpeakerLabel, "Z")
        XCTAssertNil(prepared.speakerLabelBySegmentID[unattributed.id])
        XCTAssertEqual(prepared.unknownSpeakerUtteranceIDs, ["SYN-001.1.3"])
        XCTAssertEqual(
            prepared.extractionInput.excerpts[2].speakerLabel,
            "Z",
            "the exact source label remains provider-visible even when no Participant is linked"
        )
        XCTAssertEqual(
            prepared.meeting.participants.count,
            2,
            "an unknown speaker must not silently become a third participant"
        )
    }

    func testAbsentSpeakerIsTreatedAsUnknownRatherThanADecodeFailure() throws {
        let prepared = try prepare(
            transcript: #"""
            {"utterance_id":"U1","start_seconds":0.0,"end_seconds":1.0,"speaker":null,
             "text_raw":"안녕하세요","text_normalized":"안녕하세요"}
            """#
        )

        XCTAssertEqual(prepared.unknownSpeakerUtteranceIDs, ["U1"])
        XCTAssertNil(prepared.meeting.transcriptSegments[0].speakerID)
    }

    func testAFullyMappedCaseRecordsNoUnknownSpeakers() throws {
        let prepared = try BenchmarkFixtures.prepared()

        XCTAssertTrue(prepared.unknownSpeakerUtteranceIDs.isEmpty)
    }

    func testOfflineBenchmarkSpeakerCommitmentMapsThroughTheProductMapper() throws {
        let prepared = try BenchmarkFixtures.prepared()
        let segment = prepared.meeting.transcriptSegments[1]
        let expected = try XCTUnwrap(
            prepared.meeting.participants.first(where: { $0.speakerLabel == "B" })
        )
        let result = WorkStateExtractionResult(
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "초안 작성",
                    details: nil,
                    assigneeAttribution: ProposedAssigneeAttribution(
                        basis: .speakerCommitment,
                        reference: nil,
                        speakerLabel: "B"
                    ),
                    dueDate: nil,
                    confidence: 0.8,
                    evidence: ProposedEvidence(segmentID: segment.id.uuidString, quote: segment.text)
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = WorkStateProposalMapper.map(
            result,
            meeting: prepared.meeting,
            now: BenchmarkExtractionInputAdapter.syntheticMeetingDate
        ).workState

        let item = try XCTUnwrap(mapped.actionItems.first)
        XCTAssertEqual(item.assigneeID, expected.id)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .resolved)
        XCTAssertTrue(mapped.rejected.isEmpty)
    }

    func testOfflineBenchmarkUnknownSpeakerCannotBecomeAnAssignee() throws {
        let prepared = try BenchmarkFixtures.prepared(includeUnknownSpeaker: true)
        let segment = prepared.meeting.transcriptSegments[2]
        let result = WorkStateExtractionResult(
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "초안 작성",
                    details: nil,
                    assigneeAttribution: ProposedAssigneeAttribution(
                        basis: .selfReference,
                        reference: "제가",
                        speakerLabel: "C"
                    ),
                    dueDate: nil,
                    confidence: 0.8,
                    evidence: ProposedEvidence(segmentID: segment.id.uuidString, quote: segment.text)
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let mapped = WorkStateProposalMapper.map(
            result,
            meeting: prepared.meeting,
            now: BenchmarkExtractionInputAdapter.syntheticMeetingDate
        ).workState

        let item = try XCTUnwrap(mapped.actionItems.first)
        XCTAssertNil(item.assigneeID)
        XCTAssertEqual(item.proposedAssigneeAttribution?.resolution, .missingEvidenceSpeaker)
        XCTAssertTrue(mapped.rejected.isEmpty)
    }

    // MARK: - Reverse mapping

    func testEvidenceSegmentIDMapsBackToTheCorpusUtteranceID() throws {
        let prepared = try BenchmarkFixtures.prepared()
        let segments = prepared.meeting.transcriptSegments

        XCTAssertEqual(prepared.utteranceID(forRawSegmentID: segments[0].id.uuidString), "SYN-001.1.1")
        XCTAssertEqual(prepared.utteranceID(forRawSegmentID: segments[2].id.uuidString), "SYN-001.1.3")
        XCTAssertEqual(prepared.utteranceIDBySegmentID[segments[1].id], "SYN-001.1.2")
        XCTAssertEqual(prepared.segmentIDByUtteranceID["SYN-001.1.2"], segments[1].id)
    }

    func testAnUnresolvableSegmentIDMapsBackToNil() throws {
        let prepared = try BenchmarkFixtures.prepared()

        XCTAssertNil(prepared.utteranceID(forRawSegmentID: UUID().uuidString), "well-formed but foreign")
        XCTAssertNil(prepared.utteranceID(forRawSegmentID: "not-a-uuid"), "malformed")
        XCTAssertNil(prepared.utteranceID(forRawSegmentID: ""))
        XCTAssertNil(
            prepared.utteranceID(
                forRawSegmentID: BenchmarkIdentity.segmentID(
                    benchmark: BenchmarkFixtures.benchmark,
                    caseID: "SYN-002",
                    utteranceID: "SYN-002.1.1"
                ).uuidString
            ),
            "a segment id from another case must not resolve inside this one"
        )
    }

    func testTwoCasesShareNoIdentifiers() throws {
        let first = try BenchmarkFixtures.prepared(caseID: "SYN-001")
        let second = try BenchmarkFixtures.prepared(caseID: "SYN-002")

        XCTAssertNotEqual(first.meeting.id, second.meeting.id)
        XCTAssertNotEqual(first.meeting.projectID, second.meeting.projectID)
        XCTAssertTrue(
            Set(first.meeting.transcriptSegments.map(\.id))
                .isDisjoint(with: Set(second.meeting.transcriptSegments.map(\.id)))
        )
        XCTAssertTrue(
            Set(first.meeting.participants.map(\.id))
                .isDisjoint(with: Set(second.meeting.participants.map(\.id)))
        )
    }

    // MARK: - Meeting shape

    func testTheSyntheticMeetingInventsNoDataOfItsOwn() throws {
        let prepared = try BenchmarkFixtures.prepared()
        let meeting = prepared.meeting

        XCTAssertEqual(meeting.title, "합성 픽스처 회의", "the title is the corpus topic, not a generated one")
        XCTAssertEqual(meeting.occurredAt, BenchmarkExtractionInputAdapter.syntheticMeetingDate)
        XCTAssertEqual(meeting.createdAt, BenchmarkExtractionInputAdapter.syntheticMeetingDate)
        XCTAssertEqual(BenchmarkExtractionInputAdapter.syntheticMeetingDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(meeting.sourceType, .pastedText)
        XCTAssertNil(meeting.audioAsset)
        XCTAssertTrue(meeting.speakerResolutions.isEmpty)
        XCTAssertEqual(
            meeting.id,
            BenchmarkIdentity.meetingID(benchmark: BenchmarkFixtures.benchmark, caseID: "SYN-001")
        )
        XCTAssertEqual(
            meeting.projectID,
            BenchmarkIdentity.projectID(benchmark: BenchmarkFixtures.benchmark, caseID: "SYN-001")
        )
        XCTAssertTrue(meeting.transcriptSegments.allSatisfy { $0.meetingID == meeting.id })
    }

    func testCaseMetadataIsCarriedThroughForTheArtifactHeader() throws {
        let prepared = try BenchmarkFixtures.prepared()

        XCTAssertEqual(prepared.caseID, "SYN-001")
        XCTAssertEqual(prepared.benchmark, BenchmarkFixtures.benchmark)
        XCTAssertEqual(prepared.split, .development)
        XCTAssertEqual(prepared.datasetSchemaVersion, BenchmarkCaseFile.supportedSchemaVersion)
        XCTAssertEqual(prepared.utteranceCount, 3)
        XCTAssertTrue(prepared.isGoldPending, "no case in this corpus has human-confirmed gold yet")
    }

    func testSealedHoldoutSplitDecodesFromItsCorpusSpelling() throws {
        let prepared = try BenchmarkFixtures.prepared(caseID: "SYN-H1", split: "sealed_holdout")

        XCTAssertEqual(prepared.split, .sealedHoldout)
        XCTAssertEqual(BenchmarkSplit.sealedHoldout.rawValue, "sealed_holdout")
    }

    // MARK: - Text resolution

    func testResolvedTextPrefersTheNormalizedFormAndFallsBackToRaw() throws {
        let prepared = try BenchmarkFixtures.prepared()
        let segments = prepared.meeting.transcriptSegments

        XCTAssertEqual(segments[0].text, "다음 주까지 초안을 정리하기로 했습니다.")
        XCTAssertEqual(
            segments[2].text,
            "그럼 다음 회의에서 확정하죠.",
            "a null normalization must fall back to the raw line, not to an empty segment"
        )
        XCTAssertEqual(segments[0].startTime, 0.0)
        XCTAssertEqual(segments[0].endTime, 10.0)
    }

    func testABlankNormalizationFallsBackAndABlankLineResolvesToEmpty() throws {
        let prepared = try prepare(
            transcript: #"""
            {"utterance_id":"U1","speaker":"A","text_raw":"실제 문장","text_normalized":"   "},
            {"utterance_id":"U2","speaker":"A","text_raw":null,"text_normalized":null}
            """#
        )

        XCTAssertEqual(prepared.meeting.transcriptSegments[0].text, "실제 문장")
        XCTAssertEqual(prepared.meeting.transcriptSegments[1].text, "")
        XCTAssertNil(prepared.meeting.transcriptSegments[1].startTime, "missing timings stay missing")
    }

    // MARK: - Source hash

    func testSourceCaseHashIsALowercaseSHA256OfTheRawBytes() throws {
        // The canonical SHA-256 test vector, so this asserts the digest itself and not just its shape.
        XCTAssertEqual(
            BenchmarkExtractionInputAdapter.sourceHash(of: Data("abc".utf8)),
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        let bytes = BenchmarkFixtures.caseJSON()
        let prepared = try BenchmarkFixtures.prepared()
        XCTAssertEqual(prepared.sourceCaseHash, BenchmarkExtractionInputAdapter.sourceHash(of: bytes))
        XCTAssertNotEqual(
            prepared.sourceCaseHash,
            BenchmarkExtractionInputAdapter.sourceHash(of: BenchmarkFixtures.caseJSON(caseID: "SYN-002"))
        )
    }

    // MARK: - Refusals

    func testDuplicateUtteranceIDThrowsInsteadOfOverwriting() throws {
        let transcript = #"""
        {"utterance_id":"U1","speaker":"A","text_normalized":"첫 번째"},
        {"utterance_id":"U1","speaker":"A","text_normalized":"두 번째"}
        """#

        XCTAssertThrowsError(try prepare(transcript: transcript)) { error in
            XCTAssertEqual(error as? BenchmarkAdapterError, .duplicateUtteranceID("U1"))
        }
    }

    func testUnknownSchemaVersionThrows() throws {
        let transcript = #"{"utterance_id":"U1","speaker":"A","text_normalized":"한 줄"}"#

        XCTAssertThrowsError(
            try prepare(schemaVersion: "haena-benchmark-v9.9", transcript: transcript)
        ) { error in
            XCTAssertEqual(error as? BenchmarkAdapterError, .unsupportedSchemaVersion("haena-benchmark-v9.9"))
        }
    }

    func testEmptyTranscriptThrows() throws {
        XCTAssertThrowsError(try prepare(transcript: "")) { error in
            XCTAssertEqual(error as? BenchmarkAdapterError, .emptyTranscript)
        }
    }

    // MARK: - Helpers

    /// A minimal case file built around an arbitrary transcript body, for the edge cases the shared
    /// fixture deliberately does not model.
    private func prepare(
        schemaVersion: String = "haena-benchmark-v0.1",
        transcript: String
    ) throws -> BenchmarkPreparedCase {
        let json = """
        {
          "schema_version": "\(schemaVersion)",
          "benchmark": "meeting-execution-v0",
          "case_id": "SYN-EDGE",
          "split": "development",
          "source": { "source_id": "S1", "topic": "테스트 회의", "domain": null, "media": null, "type": null },
          "speaker_mapping": { "SP0001": "A" },
          "transcript": [\(transcript)],
          "gold": { "status": "human_review_pending" }
        }
        """
        let bytes = Data(json.utf8)
        let caseFile = try BenchmarkCaseFile.decoder.decode(BenchmarkCaseFile.self, from: bytes)
        return try BenchmarkExtractionInputAdapter.prepare(caseFile: caseFile, rawCaseBytes: bytes)
    }
}
