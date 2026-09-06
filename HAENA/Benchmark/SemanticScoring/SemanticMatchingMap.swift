import CryptoKit
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Canonical SHA-256 text used by the semantic scorer boundary.
///
/// Digests are always over the supplied raw bytes and always serialize as exactly
/// `sha256:` followed by 64 lowercase ASCII hexadecimal characters.
enum SemanticSHA256Digest {
    static func rawBytes(_ data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256:" + hex
    }

    static func isCanonical(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("sha256:".utf8)
        guard bytes.count == prefix.count + 64,
              bytes.starts(with: prefix) else {
            return false
        }
        return bytes.dropFirst(prefix.count).allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// A prediction artifact fingerprint that cannot be initialized from an unverified digest string.
/// The factory hashes the artifact's exact serialized bytes; artifact file loading and CLI wiring
/// remain TM 3.6 responsibilities.
struct PredictionArtifactFingerprint: Equatable, Hashable, Sendable {
    let rawValue: String

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func rawArtifactBytes(_ data: Data) -> PredictionArtifactFingerprint {
        PredictionArtifactFingerprint(rawValue: SemanticSHA256Digest.rawBytes(data))
    }
}

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

/// A reviewer-authored duplicate relationship between two exact prediction identities.
/// No title, body, transcript, or other semantic surface is available to this declaration.
struct SemanticDuplicatePredictionDeclaration: Codable, Comparable, Equatable, Hashable, Sendable {
    let duplicate: SemanticPredictionReference
    let canonical: SemanticPredictionReference

    static func < (
        lhs: SemanticDuplicatePredictionDeclaration,
        rhs: SemanticDuplicatePredictionDeclaration
    ) -> Bool {
        if lhs.duplicate != rhs.duplicate {
            return lhs.duplicate < rhs.duplicate
        }
        return lhs.canonical < rhs.canonical
    }
}

/// Human-authored exact pairings. v0.1 remains pair-only. v0.2 adds explicit duplicate
/// declarations without changing pair semantics or inferring equivalence from text.
struct SemanticMatchingMap: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-matching-map-v0.1"
    static let duplicateSchemaVersion = "haena-semantic-matching-map-v0.2"
    static let policyVersion = "haena-explicit-one-to-one-v0.1"

    let schemaVersion: String
    let policyVersion: String
    let caseID: String
    let predictionArtifactHash: String
    /// SHA-256 of the scorer input's exact raw serialized bytes, including whitespace/newlines.
    /// The digest lives outside that payload so the fingerprint is not self-referential.
    let goldInputHash: String
    let pairs: [SemanticMatchingPair]
    let duplicatePredictions: [SemanticDuplicatePredictionDeclaration]

    init(
        schemaVersion: String = Self.schemaVersion,
        policyVersion: String = Self.policyVersion,
        caseID: String,
        predictionArtifactHash: String,
        goldInputHash: String,
        pairs: [SemanticMatchingPair],
        duplicatePredictions: [SemanticDuplicatePredictionDeclaration] = []
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.caseID = caseID
        self.predictionArtifactHash = predictionArtifactHash
        self.goldInputHash = goldInputHash
        self.pairs = pairs.sorted()
        self.duplicatePredictions = duplicatePredictions.sorted()
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        policyVersion = try container.decode(String.self, forKey: .policyVersion)
        caseID = try container.decode(String.self, forKey: .caseID)
        predictionArtifactHash = try container.decode(String.self, forKey: .predictionArtifactHash)
        goldInputHash = try container.decode(String.self, forKey: .goldInputHash)
        pairs = try container.decode([SemanticMatchingPair].self, forKey: .pairs).sorted()
        duplicatePredictions = try container.decodeIfPresent(
            [SemanticDuplicatePredictionDeclaration].self,
            forKey: .duplicatePredictions
        )?.sorted() ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(policyVersion, forKey: .policyVersion)
        try container.encode(caseID, forKey: .caseID)
        try container.encode(predictionArtifactHash, forKey: .predictionArtifactHash)
        try container.encode(goldInputHash, forKey: .goldInputHash)
        try container.encode(pairs, forKey: .pairs)
        if schemaVersion != Self.schemaVersion || !duplicatePredictions.isEmpty {
            try container.encode(duplicatePredictions, forKey: .duplicatePredictions)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyVersion = "policy_version"
        case caseID = "case_id"
        case predictionArtifactHash = "prediction_artifact_hash"
        case goldInputHash = "gold_input_hash"
        case pairs
        case duplicatePredictions = "duplicate_predictions"
    }
}
