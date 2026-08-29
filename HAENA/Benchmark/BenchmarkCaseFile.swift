import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Split

/// Which half of the corpus a case belongs to.
///
/// The raw values are the corpus's own strings, so a decode failure here means the dataset changed
/// shape — it never silently degrades into "some other split".
enum BenchmarkSplit: String, Codable, Sendable, CaseIterable {
    case development
    case sealedHoldout = "sealed_holdout"
}

// MARK: - Case file

/// One `cases/MEV0-0NN.json` file, decoded down to only what the harness is allowed to use.
///
/// Fields the harness has no business reading are deliberately absent from this type rather than
/// decoded-and-ignored: `features`, `heuristic_selection_signals_not_gold`, `window`, and the whole
/// body of `gold` never enter the process, so no later change can accidentally start feeding them
/// to a model or a report.
struct BenchmarkCaseFile: Decodable, Equatable, Sendable {
    /// The only dataset schema this harness understands. A newer corpus must fail loudly in
    /// `BenchmarkExtractionInputAdapter` rather than be interpreted under stale assumptions.
    static let supportedSchemaVersion = "haena-benchmark-v0.1"

    /// Provenance of the recording a case was cut from. Kept for the meeting title and for
    /// human-readable reporting only — `label_path` is intentionally not decoded, because it is a
    /// filesystem path into the licensed source corpus and must never reach an artifact.
    struct Source: Decodable, Equatable, Sendable {
        let sourceID: String
        let topic: String
        let domain: String?
        /// JSON `media`, e.g. "기타 녹음".
        let mediaType: String?
        /// JSON `type`, e.g. "회의".
        let meetingType: String?

        private enum CodingKeys: String, CodingKey {
            case sourceID = "source_id"
            case topic
            case domain
            case mediaType = "media"
            case meetingType = "type"
        }
    }

    /// A single transcript line as the corpus stores it.
    ///
    /// Nearly everything is optional because this is externally produced data: a missing speaker or
    /// a missing normalization is a fact about the corpus to be reported, not a decode failure that
    /// takes the whole case down.
    struct Utterance: Decodable, Equatable, Sendable {
        let utteranceID: String
        let startSeconds: Double?
        let endSeconds: Double?
        /// "A"/"B"/"C"/... — the anonymized label, or nil when the corpus could not attribute the line.
        let speaker: String?
        let sourceSpeakerID: String?
        let speakerRole: String?
        let textRaw: String?
        let textNormalized: String?

        /// `textNormalized` when present and non-blank, else `textRaw`, else "".
        ///
        /// The normalized form is preferred because it is what a reader of the transcript would
        /// quote; the raw form still carries the corpus's `(제이백오십구회)/(제259회)` disfluency
        /// markup, which no model should be asked to reproduce verbatim as evidence.
        ///
        /// The chosen string is returned trimmed of surrounding whitespace. Evidence quotes are
        /// matched as substrings of this text, so leading padding that varies between corpus
        /// revisions would otherwise make grounding depend on invisible characters.
        var resolvedText: String {
            if let normalized = textNormalized?.benchmarkTrimmedNonEmpty {
                return normalized
            }
            if let raw = textRaw?.benchmarkTrimmedNonEmpty {
                return raw
            }
            return ""
        }

        private enum CodingKeys: String, CodingKey {
            case utteranceID = "utterance_id"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case speaker
            case sourceSpeakerID = "source_speaker_id"
            case speakerRole = "speaker_role"
            case textRaw = "text_raw"
            case textNormalized = "text_normalized"
        }
    }

    /// Only the gate status is decoded. Gold *content* is deliberately never read by the harness:
    /// this task is gold-independent, and reading it would invite scoring.
    struct GoldGate: Decodable, Equatable, Sendable {
        let status: String?
    }

    let schemaVersion: String
    let benchmark: String
    let caseID: String
    let split: BenchmarkSplit
    let reviewStatus: String?
    let reviewFocus: String?
    let targetSpeaker: String?
    let source: Source
    let speakerMapping: [String: String]
    let transcript: [Utterance]
    let gold: GoldGate?

    /// The one `gold.status` value that means a human has signed off on the semantic labels.
    /// Anything else — including a status this build has never heard of — counts as pending.
    static let confirmedGoldStatus = "human_confirmed"

    /// True when no human has confirmed semantic gold for this case yet.
    ///
    /// Fail-safe by construction: an absent gold block, an absent status, or an unrecognized status
    /// all read as *pending*. Treating an unknown status as confirmed would let a future corpus
    /// revision quietly promote a prediction run into something that looks like a measured result.
    var isGoldPending: Bool {
        gold?.status != Self.confirmedGoldStatus
    }

    /// A decoder configured for this schema.
    ///
    /// No `keyDecodingStrategy` on purpose: `.convertFromSnakeCase` would map `case_id` to `caseId`
    /// and quietly fail against the repository's `caseID` naming, so every key is spelled out in
    /// `CodingKeys` instead.
    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case benchmark
        case caseID = "case_id"
        case split
        case reviewStatus = "review_status"
        case reviewFocus = "review_focus"
        case targetSpeaker = "target_speaker"
        case source
        case speakerMapping = "speaker_mapping"
        case transcript
        case gold
    }
}

// MARK: - Source index

/// One transcript-free `source-index.jsonl` line used for discovery.
///
/// Discovery must be able to answer "which case is in which split" without opening either the
/// transcript-bearing manifest or a case file. `casePath` is relative to the benchmark root and is
/// the only filesystem identifier admitted by the index contract.
struct BenchmarkSourceIndexEntry: Decodable, Equatable, Sendable {
    let caseID: String
    let split: BenchmarkSplit
    let benchmark: String
    let schemaVersion: String
    let reviewStatus: String
    let casePath: String

    private enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case split
        case benchmark
        case schemaVersion = "schema_version"
        case reviewStatus = "review_status"
        case casePath = "case_path"
    }
}

// MARK: - Helpers

private extension String {
    /// Nil for a string that is empty or only whitespace. Used to decide whether the corpus really
    /// supplied a normalized transcript line or just an empty placeholder.
    var benchmarkTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
