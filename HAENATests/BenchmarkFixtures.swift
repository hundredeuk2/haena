import Foundation
@testable import HAENA

/// Synthetic benchmark data shared by the harness tests.
///
/// Nothing here reads `data/`. The real corpus is local-only and licensed, so a test suite that
/// depended on it would fail on any machine that does not have it — and a fixture derived from it
/// would copy licensed transcript text into the repository.
enum BenchmarkFixtures {
    static let benchmark = "meeting-execution-v0"
    static let schemaVersion = "haena-benchmark-v0.1"

    // MARK: - Case JSON

    /// A two-speaker, three-utterance synthetic case JSON, as raw bytes.
    ///
    /// The third utterance deliberately has no `text_normalized`, so `resolvedText`'s fallback to
    /// `text_raw` is exercised by every test that uses this fixture rather than only by the one
    /// test that names it.
    ///
    /// - Parameter includeUnknownSpeaker: when true the third utterance is attributed to `"Z"`,
    ///   a label that appears nowhere in `speaker_mapping` — the corpus condition that produces an
    ///   input-stage `unknown_speaker` rejection.
    static func caseJSON(
        caseID: String = "SYN-001",
        split: String = "development",
        includeUnknownSpeaker: Bool = false
    ) -> Data {
        let thirdSpeaker = includeUnknownSpeaker ? "Z" : "A"
        let thirdSourceSpeaker = includeUnknownSpeaker ? "SP9999" : "SP0001"

        let json = """
        {
          "schema_version": "\(schemaVersion)",
          "benchmark": "\(benchmark)",
          "case_id": "\(caseID)",
          "split": "\(split)",
          "review_status": "human_review_pending",
          "review_focus": "synthetic_fixture",
          "target_speaker": "B",
          "source": {
            "source_id": "SYNSRC\(caseID)",
            "label_path": "synthetic/fixture.json",
            "media": "기타 녹음",
            "type": "회의",
            "domain": "사회",
            "topic": "합성 픽스처 회의",
            "topic_family": "합성 픽스처",
            "prior_source_id": null
          },
          "window": { "source_start_seconds": 0.0, "source_end_seconds": 30.0, "duration_seconds": 30.0 },
          "speaker_mapping": { "SP0001": "A", "SP0002": "B" },
          "features": { "active_speaker_count": 2, "utterance_count": 3 },
          "heuristic_selection_signals_not_gold": { "action_keyword_hits": 1 },
          "transcript": [
            {
              "utterance_id": "\(caseID).1.1",
              "start_seconds": 0.0,
              "end_seconds": 10.0,
              "speaker": "A",
              "source_speaker_id": "SP0001",
              "speaker_role": "사회자",
              "text_raw": "다음 주까지 초안을 정리하기로 했습니다. /(noise)",
              "text_normalized": "다음 주까지 초안을 정리하기로 했습니다.",
              "environment": "잡음"
            },
            {
              "utterance_id": "\(caseID).1.2",
              "start_seconds": 10.0,
              "end_seconds": 20.0,
              "speaker": "B",
              "source_speaker_id": "SP0002",
              "speaker_role": "발언자",
              "text_raw": "제가 지표 정의를 맡겠습니다.",
              "text_normalized": "제가 지표 정의를 맡겠습니다.",
              "environment": null
            },
            {
              "utterance_id": "\(caseID).1.3",
              "start_seconds": 20.0,
              "end_seconds": 30.0,
              "speaker": "\(thirdSpeaker)",
              "source_speaker_id": "\(thirdSourceSpeaker)",
              "speaker_role": "사회자",
              "text_raw": "그럼 다음 회의에서 확정하죠.",
              "text_normalized": null,
              "environment": null
            }
          ],
          "prior_state": null,
          "gold": {
            "status": "human_review_pending",
            "decisions": null,
            "action_items": null,
            "open_questions": null,
            "next_agenda": null,
            "expected_state_transitions": null,
            "forbidden_inferences": null,
            "reviewer_notes": ""
          }
        }
        """
        return Data(json.utf8)
    }

    static func caseFile(
        caseID: String = "SYN-001",
        split: String = "development",
        includeUnknownSpeaker: Bool = false
    ) throws -> BenchmarkCaseFile {
        try BenchmarkCaseFile.decoder.decode(
            BenchmarkCaseFile.self,
            from: caseJSON(caseID: caseID, split: split, includeUnknownSpeaker: includeUnknownSpeaker)
        )
    }

    static func prepared(
        caseID: String = "SYN-001",
        split: String = "development",
        includeUnknownSpeaker: Bool = false
    ) throws -> BenchmarkPreparedCase {
        let bytes = caseJSON(caseID: caseID, split: split, includeUnknownSpeaker: includeUnknownSpeaker)
        let file = try BenchmarkCaseFile.decoder.decode(BenchmarkCaseFile.self, from: bytes)
        return try BenchmarkExtractionInputAdapter.prepare(caseFile: file, rawCaseBytes: bytes)
    }

    // MARK: - Temporary dataset

    /// Writes a synthetic dataset root (source-index.jsonl + cases/) into a temporary directory and
    /// returns its URL. Caller deletes it.
    ///
    /// Holdout cases get real files on disk even though no test may read them: the sealed-holdout
    /// gate is only meaningfully tested by *deleting* those files and checking that the refusal is
    /// unchanged, which proves the gate fired before any read.
    static func writeTemporaryDataset(
        developmentCaseIDs: [String],
        sealedHoldoutCaseIDs: [String]
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("haena-benchmark-fixture-\(UUID().uuidString)", isDirectory: true)
        let casesDirectory = root.appendingPathComponent("cases", isDirectory: true)
        try fileManager.createDirectory(at: casesDirectory, withIntermediateDirectories: true)

        var sourceIndexLines: [String] = []
        for (caseIDs, split) in [(developmentCaseIDs, "development"), (sealedHoldoutCaseIDs, "sealed_holdout")] {
            for caseID in caseIDs {
                try caseJSON(caseID: caseID, split: split).write(
                    to: casesDirectory.appendingPathComponent("\(caseID).json")
                )
                sourceIndexLines.append(sourceIndexLine(caseID: caseID, split: split))
            }
        }

        // Trailing newline, as in the real corpus: a reader that splits on newlines must cope with
        // the empty final element rather than treating it as a malformed line.
        let sourceIndex = sourceIndexLines.joined(separator: "\n") + "\n"
        try Data(sourceIndex.utf8).write(to: root.appendingPathComponent("source-index.jsonl"))
        return root
    }

    /// A source-index line carries only what discovery needs and never a transcript.
    private static func sourceIndexLine(caseID: String, split: String) -> String {
        """
        {"schema_version":"\(schemaVersion)","benchmark":"\(benchmark)","case_id":"\(caseID)",\
        "split":"\(split)","review_status":"human_review_pending","case_path":"cases/\(caseID).json"}
        """
    }

    // MARK: - Run options

    /// Fixed run options for harness tests. Every provenance field is a literal so an artifact
    /// produced in a test never varies with the machine it ran on.
    static let runOptions = BenchmarkRunOptions(
        benchmark: BenchmarkFixtures.benchmark,
        provider: .offlineStub,
        modelID: "benchmark-stub-v1",
        promptRevision: "benchmark-stub-v1",
        extractionSchemaVersion: "work_state_extraction",
        gitRevision: "testrev"
    )
}
