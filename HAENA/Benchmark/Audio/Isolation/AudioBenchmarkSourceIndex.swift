import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum AudioBenchmarkSplit: String, Codable, Equatable, Sendable {
    case development
    case sealedHoldout = "sealed_holdout"
}

/// The complete and deliberately finite audio discovery surface.
///
/// This type contains no transcript, gold, source-audio path, speaker mapping, duration, or source
/// identity. Discovery can therefore authorize a split without bringing any sealed content into
/// memory. Exact-key validation is performed by `AudioBenchmarkCaseStore` before decoding because
/// `JSONDecoder` otherwise ignores unknown keys.
struct AudioBenchmarkSourceIndexEntry: Codable, Equatable, Sendable {
    let schemaVersion: String
    let benchmark: String
    let caseID: String
    let split: AudioBenchmarkSplit
    let reviewStatus: String
    let casePath: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case benchmark
        case caseID = "case_id"
        case split
        case reviewStatus = "review_status"
        case casePath = "case_path"
    }
}

enum AudioBenchmarkSelection: Equatable, Sendable {
    case development
    case caseIDs([String])
    case sealedHoldout
}

/// Errors intentionally carry no path, decoded payload, or sealed case identifier.
enum AudioBenchmarkIsolationError: Error, Equatable, Sendable {
    case sourceIndexNotFound
    case malformedSourceIndexLine(lineNumber: Int)
    case duplicateCaseID
    case unknownCaseID
    case sealedHoldoutLocked
    case caseFileNotFound
    case invalidRelativePath
    case sourceAssetNotFound
}
