import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Exact identity of one mapped prediction. `artifactFingerprint` binds the UUID to the exact
/// immutable prediction artifact whose bytes were reviewed; the UUID is never reconstructed from
/// text or provider output here.
struct SemanticPredictionReference: Codable, Comparable, Equatable, Hashable, Sendable {
    let artifactFingerprint: String
    let caseID: String
    let kind: SemanticScoringOutputKind
    let proposalID: UUID

    static func < (lhs: SemanticPredictionReference, rhs: SemanticPredictionReference) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [artifactFingerprint, caseID, kind.rawValue, proposalID.uuidString].joined(separator: "\u{1F}")
    }

    private enum CodingKeys: String, CodingKey {
        case artifactFingerprint = "artifact_fingerprint"
        case caseID = "case_id"
        case kind
        case proposalID = "proposal_id"
    }
}

/// Exact identity of one gold output. The scorer-input schema version is part of the identity, so
/// a future schema cannot silently reinterpret an old GoldOutputID.
struct SemanticGoldReference: Codable, Comparable, Equatable, Hashable, Sendable {
    let inputSchemaVersion: String
    let caseID: String
    let kind: SemanticScoringOutputKind
    let outputID: GoldOutputID

    static func < (lhs: SemanticGoldReference, rhs: SemanticGoldReference) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [inputSchemaVersion, caseID, kind.rawValue, outputID.rawValue].joined(separator: "\u{1F}")
    }

    private enum CodingKeys: String, CodingKey {
        case inputSchemaVersion = "input_schema_version"
        case caseID = "case_id"
        case kind
        case outputID = "output_id"
    }
}

struct SemanticMatchingPair: Codable, Comparable, Equatable, Hashable, Sendable {
    let prediction: SemanticPredictionReference
    let gold: SemanticGoldReference

    static func < (lhs: SemanticMatchingPair, rhs: SemanticMatchingPair) -> Bool {
        if lhs.prediction != rhs.prediction {
            return lhs.prediction < rhs.prediction
        }
        return lhs.gold < rhs.gold
    }
}

/// Human-authored exact pairings. This type only records and validates one-to-one identity links;
/// TP/FP/FN accounting deliberately belongs to TM 3.3.
struct SemanticMatchingMap: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-matching-map-v0.1"
    static let policyVersion = "haena-explicit-one-to-one-v0.1"

    let schemaVersion: String
    let policyVersion: String
    let caseID: String
    let predictionArtifactHash: String
    let goldInputHash: String
    let pairs: [SemanticMatchingPair]

    init(
        schemaVersion: String = Self.schemaVersion,
        policyVersion: String = Self.policyVersion,
        caseID: String,
        predictionArtifactHash: String,
        goldInputHash: String,
        pairs: [SemanticMatchingPair]
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.caseID = caseID
        self.predictionArtifactHash = predictionArtifactHash
        self.goldInputHash = goldInputHash
        self.pairs = pairs.sorted()
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyVersion = "policy_version"
        case caseID = "case_id"
        case predictionArtifactHash = "prediction_artifact_hash"
        case goldInputHash = "gold_input_hash"
        case pairs
    }
}
