import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum SemanticPredictionEvidenceState: String, Codable, Equatable, Sendable {
    case known
    case absent
    case unresolved
}

struct SemanticPredictionEvidenceObservation: Codable, Equatable, Sendable {
    let state: SemanticPredictionEvidenceState
    let utteranceIDs: [String]

    init(state: SemanticPredictionEvidenceState, utteranceIDs: [String] = []) {
        self.state = state
        self.utteranceIDs = utteranceIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case utteranceIDs = "utterance_ids"
    }
}

enum SemanticPredictionTargetResponsibility: String, Codable, Equatable, Sendable {
    case targetSpeakerResponsible = "b_responsible"
    case otherSpeaker = "other_speaker"
    case noResponsibilityAssigned = "no_responsibility_assigned"
    case unresolved
}

enum SemanticPredictionAssigneeState: String, Codable, Equatable, Sendable {
    case known
    case absent
    case unresolved
    case incomparable
}

/// A typed prediction-side assignee observation. `valueReference` is opaque and exact; callers
/// cannot provide a display name and this layer never normalizes or interprets its contents.
struct SemanticPredictionAssigneeObservation: Codable, Equatable, Sendable {
    let state: SemanticPredictionAssigneeState
    let scope: SemanticAssigneeScope?
    let basis: SemanticAssigneeBasis?
    let valueReference: String?
    let evidenceUtteranceIDs: [String]

    init(
        state: SemanticPredictionAssigneeState,
        scope: SemanticAssigneeScope? = nil,
        basis: SemanticAssigneeBasis? = nil,
        valueReference: String? = nil,
        evidenceUtteranceIDs: [String] = []
    ) {
        self.state = state
        self.scope = scope
        self.basis = basis
        self.valueReference = valueReference
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case scope
        case basis
        case valueReference = "value_reference"
        case evidenceUtteranceIDs = "evidence_utterance_ids"
    }
}

enum SemanticPredictionDueStatus: String, Codable, Equatable, Sendable {
    case explicit
    case explicitRelative = "explicit_relative"
    case absent
    case unresolved
    case incomparable
}

struct SemanticPredictionDueObservation: Codable, Equatable, Sendable {
    let status: SemanticPredictionDueStatus
    let value: String?
    let evidenceUtteranceIDs: [String]

    init(
        status: SemanticPredictionDueStatus,
        value: String? = nil,
        evidenceUtteranceIDs: [String] = []
    ) {
        self.status = status
        self.value = value
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case value
        case evidenceUtteranceIDs = "evidence_utterance_ids"
    }
}

/// Versioned, transcript-free metric observations for one exact prediction identity.
struct SemanticPredictionMetricObservation: Codable, Comparable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-prediction-metric-observation-v0.1"

    let schemaVersion: String
    let predictionReference: SemanticPredictionReference
    let evidence: SemanticPredictionEvidenceObservation
    let targetResponsibility: SemanticPredictionTargetResponsibility
    let assignee: SemanticPredictionAssigneeObservation
    let due: SemanticPredictionDueObservation

    init(
        schemaVersion: String = Self.schemaVersion,
        predictionReference: SemanticPredictionReference,
        evidence: SemanticPredictionEvidenceObservation,
        targetResponsibility: SemanticPredictionTargetResponsibility,
        assignee: SemanticPredictionAssigneeObservation,
        due: SemanticPredictionDueObservation
    ) {
        self.schemaVersion = schemaVersion
        self.predictionReference = predictionReference
        self.evidence = evidence
        self.targetResponsibility = targetResponsibility
        self.assignee = assignee
        self.due = due
    }

    static func < (
        lhs: SemanticPredictionMetricObservation,
        rhs: SemanticPredictionMetricObservation
    ) -> Bool {
        lhs.predictionReference < rhs.predictionReference
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case predictionReference = "prediction_reference"
        case evidence
        case targetResponsibility = "target_responsibility"
        case assignee
        case due
    }
}

/// Canonical inventory wrapper. Authorization requires this identity set to equal the complete
/// available-prediction inventory exactly; missing, repeated, and extra records fail closed.
struct SemanticPredictionMetricObservationSet: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-prediction-metric-observations-v0.1"

    let schemaVersion: String
    let observations: [SemanticPredictionMetricObservation]

    init(
        schemaVersion: String = Self.schemaVersion,
        observations: [SemanticPredictionMetricObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.observations = observations.sorted()
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case observations
    }
}
