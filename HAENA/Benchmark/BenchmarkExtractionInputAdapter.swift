import CryptoKit
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Prepared case

/// One benchmark case turned into exactly what the app's extraction seam takes, plus the
/// bookkeeping needed to translate the model's answer back into corpus terms.
///
/// The two id dictionaries are the whole reason this type exists. The app speaks `UUID`, the corpus
/// speaks `DGBEC21000067.1.1.1`, and an artifact that only recorded one of them would be either
/// unreadable against the dataset or unverifiable against the run.
struct BenchmarkPreparedCase: Equatable, Sendable {
    let caseID: String
    let benchmark: String
    let split: BenchmarkSplit
    let datasetSchemaVersion: String
    /// `"sha256:<hex>"` over the case file's raw bytes, so an artifact can be invalidated when the
    /// corpus file behind it changes — without the artifact containing any of that file's content.
    let sourceCaseHash: String
    let isGoldPending: Bool
    /// Synthetic, in-memory only. Never saved through any `ProjectRepository`.
    let meeting: Meeting
    let extractionInput: WorkStateExtractionInput
    let utteranceIDBySegmentID: [UUID: String]
    let segmentIDByUtteranceID: [String: UUID]
    let speakerLabelBySegmentID: [UUID: String]
    /// Utterances whose `speaker` is absent or missing from `speaker_mapping`'s values.
    /// Reported as input-stage rejections; their segments still carry a nil `speakerID`.
    let unknownSpeakerUtteranceIDs: [String]
    let utteranceCount: Int

    /// The corpus utterance id a model-cited segment id refers to, or nil when it resolves to
    /// nothing in this case.
    ///
    /// Takes a `String` rather than a `UUID` because the input is whatever the model echoed back:
    /// a malformed id and a well-formed id belonging to another case are both "not of this case",
    /// and both must answer nil rather than crash a run.
    func utteranceID(forRawSegmentID raw: String) -> String? {
        guard let segmentID = UUID(uuidString: raw) else {
            return nil
        }
        return utteranceIDBySegmentID[segmentID]
    }
}

// MARK: - Errors

/// Why a case could not be turned into extractor input at all.
///
/// Every case is a refusal to guess: an unknown schema, a case with nothing to read, and a corpus
/// file that names the same utterance twice are all conditions where continuing would silently
/// produce a run whose artifact cannot be trusted.
enum BenchmarkAdapterError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(String)
    case emptyTranscript
    case duplicateUtteranceID(String)
}

// MARK: - Adapter

enum BenchmarkExtractionInputAdapter {
    /// Corpus cases carry no meeting date, so every synthetic meeting uses this fixed instant.
    /// A real date would be invented data, and a moving one would break reproducibility.
    static let syntheticMeetingDate = Date(timeIntervalSince1970: 0)

    static func prepare(
        caseFile: BenchmarkCaseFile,
        rawCaseBytes: Data,
        authorizedSplit: BenchmarkSplit? = nil
    ) throws -> BenchmarkPreparedCase {
        guard caseFile.schemaVersion == BenchmarkCaseFile.supportedSchemaVersion else {
            throw BenchmarkAdapterError.unsupportedSchemaVersion(caseFile.schemaVersion)
        }
        guard !caseFile.transcript.isEmpty else {
            throw BenchmarkAdapterError.emptyTranscript
        }

        let benchmark = caseFile.benchmark
        let caseID = caseFile.caseID
        let meetingID = BenchmarkIdentity.meetingID(benchmark: benchmark, caseID: caseID)
        let projectID = BenchmarkIdentity.projectID(benchmark: benchmark, caseID: caseID)

        // One participant per *label* (A/B/C/…), not per source speaker id: several source ids can
        // map onto one anonymized label, and the transcript only ever cites the label.
        let speakerLabels = Set(caseFile.speakerMapping.values).sorted()
        let participants = speakerLabels.map { label in
            Participant(
                id: BenchmarkIdentity.participantID(benchmark: benchmark, caseID: caseID, speaker: label),
                // The corpus is anonymized and states no names. Inventing one here would put
                // fabricated personal data into every artifact, so the label is the display name.
                displayName: label,
                linkedUserID: nil,
                speakerLabel: label
            )
        }
        let participantIDByLabel = Dictionary(
            uniqueKeysWithValues: zip(speakerLabels, participants.map(\.id))
        )

        var segments: [TranscriptSegment] = []
        var utteranceIDBySegmentID: [UUID: String] = [:]
        var segmentIDByUtteranceID: [String: UUID] = [:]
        var speakerLabelBySegmentID: [UUID: String] = [:]
        var unknownSpeakerUtteranceIDs: [String] = []

        segments.reserveCapacity(caseFile.transcript.count)

        for utterance in caseFile.transcript {
            let utteranceID = utterance.utteranceID
            guard segmentIDByUtteranceID[utteranceID] == nil else {
                // Overwriting would drop a line of transcript and make the artifact's reverse
                // mapping point at whichever duplicate happened to come last.
                throw BenchmarkAdapterError.duplicateUtteranceID(utteranceID)
            }

            let segmentID = BenchmarkIdentity.segmentID(
                benchmark: benchmark,
                caseID: caseID,
                utteranceID: utteranceID
            )

            // A speaker the mapping does not know is reported, not repaired: the segment keeps a
            // nil `speakerID` so nothing downstream can attribute the line to the wrong person.
            let resolvedLabel = utterance.speaker.flatMap { label in
                participantIDByLabel[label] == nil ? nil : label
            }
            if let resolvedLabel {
                speakerLabelBySegmentID[segmentID] = resolvedLabel
            } else {
                unknownSpeakerUtteranceIDs.append(utteranceID)
            }

            segments.append(
                TranscriptSegment(
                    id: segmentID,
                    meetingID: meetingID,
                    speakerID: resolvedLabel.flatMap { participantIDByLabel[$0] },
                    sourceSpeakerLabel: utterance.speaker,
                    text: utterance.resolvedText,
                    startTime: utterance.startSeconds,
                    endTime: utterance.endSeconds
                )
            )
            utteranceIDBySegmentID[segmentID] = utteranceID
            segmentIDByUtteranceID[utteranceID] = segmentID
        }

        let meeting = Meeting(
            id: meetingID,
            projectID: projectID,
            title: caseFile.source.topic,
            occurredAt: syntheticMeetingDate,
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: segments,
            createdAt: syntheticMeetingDate,
            audioAsset: nil,
            speakerResolutions: []
        )

        return BenchmarkPreparedCase(
            caseID: caseID,
            benchmark: benchmark,
            // Discovery authorization belongs to the transcript-free source index. A metadata-only
            // split rotation intentionally leaves the transcript-bearing case bytes untouched, so
            // their historical split field must not overrule the authorized index entry.
            split: authorizedSplit ?? caseFile.split,
            datasetSchemaVersion: caseFile.schemaVersion,
            sourceCaseHash: sourceHash(of: rawCaseBytes),
            isGoldPending: caseFile.isGoldPending,
            meeting: meeting,
            // The app's own initializer, on purpose: the harness must exercise the same input
            // construction the product uses, not a benchmark-only lookalike.
            extractionInput: WorkStateExtractionInput(meeting: meeting),
            utteranceIDBySegmentID: utteranceIDBySegmentID,
            segmentIDByUtteranceID: segmentIDByUtteranceID,
            speakerLabelBySegmentID: speakerLabelBySegmentID,
            unknownSpeakerUtteranceIDs: unknownSpeakerUtteranceIDs,
            utteranceCount: caseFile.transcript.count
        )
    }

    // MARK: - Hashing

    /// Digests the file exactly as it sits on disk. Hashing the decoded model instead would make
    /// the hash blind to any field this type chose not to decode — including `gold`.
    static func sourceHash(of rawCaseBytes: Data) -> String {
        let digest = SHA256.hash(data: rawCaseBytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:" + hex
    }
}
