import CryptoKit
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

struct AudioBenchmarkRunCase: Sendable {
    let caseID: String
    let split: BenchmarkSplit
    let sourceClip: AudioBenchmarkSourceClip
    let reference: AudioBenchmarkReferenceTranscript
}

struct AudioBenchmarkRunConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-audio-benchmark-run-v0.1"

    let schemaVersion: String
    let benchmark: String
    let metricSchemaVersion: String
    let providerID: String
    let modelID: String
    let caseIDs: [String]

    init(
        benchmark: String = "audio-robustness-v0",
        metricSchemaVersion: String,
        providerID: String,
        modelID: String,
        caseIDs: [String]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.benchmark = benchmark
        self.metricSchemaVersion = metricSchemaVersion
        self.providerID = providerID
        self.modelID = modelID
        self.caseIDs = caseIDs.sorted()
    }

    var canonicalHash: String {
        let data = (try? Self.encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && Self.isSafeIdentifier(benchmark, maximumLength: 80)
            && Self.isSafeIdentifier(metricSchemaVersion, maximumLength: 80)
            && Self.isSafeIdentifier(providerID, maximumLength: 80)
            && Self.isSafeIdentifier(modelID, maximumLength: 120)
            && !caseIDs.isEmpty
            && Set(caseIDs).count == caseIDs.count
            && caseIDs.allSatisfy { Self.isSafeIdentifier($0, maximumLength: 80) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    private static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
                .contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case benchmark
        case metricSchemaVersion = "metric_schema_version"
        case providerID = "provider_id"
        case modelID = "model_id"
        case caseIDs = "case_ids"
    }
}

enum AudioBenchmarkCaseStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

enum AudioBenchmarkFailureCategory: String, Codable, Equatable, Sendable {
    case sourceMissing = "source_missing"
    case sourceFormatInvalid = "source_format_invalid"
    case clipExtractionFailed = "clip_extraction_failed"
    case providerFailed = "provider_failed"
    case providerTimeout = "provider_timeout"
    case predictionInvalid = "prediction_invalid"
    case referenceInvalid = "reference_invalid"
    case scoringFailed = "scoring_failed"
    case outputWriteFailed = "output_write_failed"
}

enum AudioBenchmarkDiagnosticCode: String, Codable, Equatable, Sendable {
    case sourceType = "ABR_SOURCE_TYPE"
    case sourceMissing = "ABR_SOURCE_MISSING"
    case sourceUnreadable = "ABR_SOURCE_UNREADABLE"
    case audioFormat = "ABR_AUDIO_FORMAT"
    case sampleFormat = "ABR_SAMPLE_FORMAT"
    case frameRange = "ABR_FRAME_RANGE"
    case temporaryDirectory = "ABR_TEMP_DIRECTORY"
    case clipWrite = "ABR_CLIP_WRITE"
    case temporaryCleanup = "ABR_TEMP_CLEANUP"
    case providerCredential = "ABR_PROVIDER_CREDENTIAL"
    case providerUnauthorized = "ABR_PROVIDER_UNAUTHORIZED"
    case providerRateLimited = "ABR_PROVIDER_RATE_LIMITED"
    case providerTimeout = "ABR_PROVIDER_TIMEOUT"
    case providerNetwork = "ABR_PROVIDER_NETWORK"
    case providerRejected = "ABR_PROVIDER_REJECTED"
    case providerUnavailable = "ABR_PROVIDER_UNAVAILABLE"
    case providerResponse = "ABR_PROVIDER_RESPONSE"
    case predictionContract = "ABR_PREDICTION_CONTRACT"
    case referenceContract = "ABR_REFERENCE_CONTRACT"
    case scoringContract = "ABR_SCORING_CONTRACT"
    case artifactWrite = "ABR_ARTIFACT_WRITE"
}

struct AudioBenchmarkCaseReport: Codable, Equatable, Sendable {
    let caseID: String
    let split: BenchmarkSplit
    let providerID: String
    let modelID: String
    let metricSchemaVersion: String
    let configurationHash: String
    let status: AudioBenchmarkCaseStatus
    let cer: AudioBenchmarkMetricValue?
    let speakerCountError: Int?
    let der: AudioBenchmarkMetricValue?
    let speakerAttributionAccuracy: AudioBenchmarkMetricValue?
    let targetSpeakerBF1: AudioBenchmarkMetricValue?
    let speakerAttributedCER: AudioBenchmarkMetricValue?
    let realTimeFactor: AudioBenchmarkMetricValue?
    let failureCategory: AudioBenchmarkFailureCategory?
    let diagnosticCode: AudioBenchmarkDiagnosticCode?
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case split
        case providerID = "provider_id"
        case modelID = "model_id"
        case metricSchemaVersion = "metric_schema_version"
        case configurationHash = "configuration_hash"
        case status
        case cer
        case speakerCountError = "speaker_count_error"
        case der
        case speakerAttributionAccuracy = "speaker_attribution_accuracy"
        case targetSpeakerBF1 = "target_speaker_b_f1"
        case speakerAttributedCER = "speaker_attributed_cer"
        case realTimeFactor = "real_time_factor"
        case failureCategory = "failure_category"
        case diagnosticCode = "diagnostic_code"
        case timestamp
    }
}

struct AudioBenchmarkMetricSummary: Codable, Equatable, Sendable {
    let sampleCount: Int
    let mean: Double?
    let median: Double?
    let p95: Double?

    private enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count"
        case mean
        case median
        case p95
    }
}

struct AudioBenchmarkUnavailableReasonCount: Codable, Equatable, Sendable {
    let reason: AudioBenchmarkMetricUnavailableReason
    let count: Int
}

struct AudioBenchmarkMetricAvailability: Codable, Equatable, Sendable {
    let metric: String
    let unavailable: [AudioBenchmarkUnavailableReasonCount]
}

struct AudioBenchmarkAggregateReport: Codable, Equatable, Sendable {
    let benchmark: String
    let configurationHash: String
    let targetCount: Int
    let completedCount: Int
    let successCount: Int
    let failureCount: Int
    let timeoutCount: Int
    let resumedCount: Int
    let isComplete: Bool
    let cer: AudioBenchmarkMetricSummary
    let speakerCountError: AudioBenchmarkMetricSummary
    let der: AudioBenchmarkMetricSummary
    let speakerAttributionAccuracy: AudioBenchmarkMetricSummary
    let targetSpeakerBF1: AudioBenchmarkMetricSummary
    let speakerAttributedCER: AudioBenchmarkMetricSummary
    let realTimeFactor: AudioBenchmarkMetricSummary
    let unavailableMetrics: [AudioBenchmarkMetricAvailability]
    let startedAt: Date
    let finishedAt: Date

    private enum CodingKeys: String, CodingKey {
        case benchmark
        case configurationHash = "configuration_hash"
        case targetCount = "target_count"
        case completedCount = "completed_count"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case timeoutCount = "timeout_count"
        case resumedCount = "resumed_count"
        case isComplete = "is_complete"
        case cer
        case speakerCountError = "speaker_count_error"
        case der
        case speakerAttributionAccuracy = "speaker_attribution_accuracy"
        case targetSpeakerBF1 = "target_speaker_b_f1"
        case speakerAttributedCER = "speaker_attributed_cer"
        case realTimeFactor = "real_time_factor"
        case unavailableMetrics = "unavailable_metrics"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

enum AudioBenchmarkRunError: String, Error, Equatable, Sendable {
    case sealedHoldoutDenied
    case invalidConfiguration
    case providerConfigurationMismatch
    case outputDirectoryConflict
    case resumeConfigurationMissing
    case resumeConfigurationMismatch
    case resumeArtifactInvalid
    case outputWriteFailed
}
