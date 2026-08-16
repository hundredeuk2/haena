import Foundation

// MARK: - Provider-normalized transcript

/// The only provider result the audio benchmark accepts.
///
/// Provider-specific response bodies, request metadata, credentials, and filesystem paths have no
/// representation here, so they cannot accidentally flow into a benchmark report.
struct PredictedTranscript: Codable, Equatable, Sendable {
    let providerID: String
    let modelID: String
    /// End-to-end provider wall-clock time. A live adapter includes network waiting in this value.
    let processingDurationSeconds: Double
    let audioDurationSeconds: Double
    let segments: [PredictedSegment]

    init(
        providerID: String,
        modelID: String,
        processingDurationSeconds: Double,
        audioDurationSeconds: Double,
        segments: [PredictedSegment]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.processingDurationSeconds = processingDurationSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case modelID = "model_id"
        case processingDurationSeconds = "processing_duration_seconds"
        case audioDurationSeconds = "audio_duration_seconds"
        case segments
    }
}

struct PredictedSegment: Codable, Equatable, Sendable {
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let predictedSpeakerLabel: String
    let text: String

    init(
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        predictedSpeakerLabel: String,
        text: String
    ) {
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.predictedSpeakerLabel = predictedSpeakerLabel
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case startTimeSeconds = "start_time_seconds"
        case endTimeSeconds = "end_time_seconds"
        case predictedSpeakerLabel = "predicted_speaker_label"
        case text
    }
}

// MARK: - Reference transcript

/// Gold needed by the scorer after a development case has passed split authorization.
///
/// `textNormalized` is intentionally the only text form admitted. The scorer must never fall back
/// to raw transcript text because doing so would make CER depend on corpus markup.
struct AudioBenchmarkReferenceTranscript: Equatable, Sendable {
    let audioDurationSeconds: Double
    let targetSpeakerLabel: String
    let segments: [AudioBenchmarkReferenceSegment]

    init(
        audioDurationSeconds: Double,
        targetSpeakerLabel: String = "B",
        segments: [AudioBenchmarkReferenceSegment]
    ) {
        self.audioDurationSeconds = audioDurationSeconds
        self.targetSpeakerLabel = targetSpeakerLabel
        self.segments = segments
    }
}

struct AudioBenchmarkReferenceSegment: Equatable, Sendable {
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let speakerLabel: String
    let textNormalized: String

    init(
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        speakerLabel: String,
        textNormalized: String
    ) {
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.speakerLabel = speakerLabel
        self.textNormalized = textNormalized
    }
}

// MARK: - Metric result

enum AudioBenchmarkMetricUnavailableReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// CER and SA-CER have no defensible denominator when normalized reference text is empty.
    case emptyReferenceText = "empty_reference_text"
    /// Time metrics have no defensible denominator when the reference contains no speech.
    case noReferenceSpeech = "no_reference_speech"
    /// Target-speaker F1 is not zero when the requested target is absent from gold; it is undefined.
    case targetSpeakerAbsent = "target_speaker_absent"
}

/// A finite metric value or one finite reason why that metric cannot be calculated.
///
/// The constructors keep the two states mutually exclusive, which prevents a report from carrying
/// both a plausible-looking number and an explanation that the number was unavailable.
struct AudioBenchmarkMetricValue: Codable, Equatable, Sendable {
    let value: Double?
    let unavailableReason: AudioBenchmarkMetricUnavailableReason?

    static func measured(_ value: Double) -> AudioBenchmarkMetricValue {
        AudioBenchmarkMetricValue(value: value, unavailableReason: nil)
    }

    static func unavailable(_ reason: AudioBenchmarkMetricUnavailableReason) -> AudioBenchmarkMetricValue {
        AudioBenchmarkMetricValue(value: nil, unavailableReason: reason)
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case unavailableReason = "unavailable_reason"
    }
}

struct AudioBenchmarkScore: Codable, Equatable, Sendable {
    static let metricSchemaVersion = "haena-audio-stt-metrics-v0.1"

    /// Predicted label -> anonymized reference label. Labels with no positive time overlap are absent.
    let speakerMapping: [String: String]
    let cer: AudioBenchmarkMetricValue
    /// Signed error: predicted distinct speaker count minus reference distinct speaker count.
    let speakerCountError: Int
    let der: AudioBenchmarkMetricValue
    let speakerAttributionAccuracy: AudioBenchmarkMetricValue
    let targetSpeakerBF1: AudioBenchmarkMetricValue
    let speakerAttributedCER: AudioBenchmarkMetricValue
    let realTimeFactor: AudioBenchmarkMetricValue
}

// MARK: - Finite validation errors

enum AudioBenchmarkScoringDiagnosticCode: String, Codable, Equatable, Sendable {
    case predictionAudioDurationInvalid = "prediction_audio_duration_invalid"
    case referenceAudioDurationInvalid = "reference_audio_duration_invalid"
    case audioDurationMismatch = "audio_duration_mismatch"
    case processingDurationInvalid = "processing_duration_invalid"
    case providerIdentifierEmpty = "provider_identifier_empty"
    case modelIdentifierEmpty = "model_identifier_empty"
    case targetSpeakerLabelEmpty = "target_speaker_label_empty"
    case segmentTimeNotFinite = "segment_time_not_finite"
    case segmentTimeNegative = "segment_time_negative"
    case segmentEndNotAfterStart = "segment_end_not_after_start"
    case segmentOutsideClip = "segment_outside_clip"
    case segmentSpeakerLabelEmpty = "segment_speaker_label_empty"
    case segmentTextEmpty = "segment_text_empty"
    case overlappingPredictionSegments = "overlapping_prediction_segments"
    case overlappingReferenceSegments = "overlapping_reference_segments"
    case arithmeticOverflow = "arithmetic_overflow"
}

/// Safe scorer failure detail suitable for mapping to a report diagnostic code.
///
/// Indices refer only to the in-memory normalized arrays. No provider error text, transcript text,
/// speaker name, or path is retained.
struct AudioBenchmarkScoringError: Error, Equatable, Sendable {
    let code: AudioBenchmarkScoringDiagnosticCode
    let segmentIndex: Int?
    let conflictingSegmentIndex: Int?

    init(
        code: AudioBenchmarkScoringDiagnosticCode,
        segmentIndex: Int? = nil,
        conflictingSegmentIndex: Int? = nil
    ) {
        self.code = code
        self.segmentIndex = segmentIndex
        self.conflictingSegmentIndex = conflictingSegmentIndex
    }
}
