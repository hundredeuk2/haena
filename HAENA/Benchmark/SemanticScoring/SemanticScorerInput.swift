import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// The four semantic output collections. This is intentionally separate from the prediction
/// artifact's serialized enum: a scorer schema can evolve only by changing its own version, not by
/// weakening `prediction-v0.2`.
enum SemanticScoringOutputKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case decision
    case actionItem = "action_item"
    case openQuestion = "open_question"
    case nextAgenda = "next_agenda"

    init(_ predictionKind: BenchmarkProposalKind) {
        switch predictionKind {
        case .decision:
            self = .decision
        case .actionItem:
            self = .actionItem
        case .openQuestion:
            self = .openQuestion
        case .agendaItem:
            self = .nextAgenda
        }
    }
}

/// A human-assigned opaque identity. It is never derived from a title, transcript, name, or model
/// output, so the scorer has no text surface from which it could invent semantic equivalence.
struct GoldOutputID: RawRepresentable, Codable, Comparable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: GoldOutputID, rhs: GoldOutputID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SemanticScorerInputStatus: String, Codable, Equatable, Sendable {
    case pending
    case primaryNormalizedPendingSecondaryReview = "primary_normalized_pending_secondary_review"
    case secondaryReviewInProgress = "secondary_review_in_progress"
    case scorerReady = "scorer_ready"
}

enum SemanticInferenceClass: String, Codable, Equatable, Sendable {
    case explicit
    case derivedProposal = "derived_proposal"
    case forbiddenInference = "forbidden_inference"
}

enum SemanticTargetSpeakerResponsibility: String, Codable, Equatable, Sendable {
    case targetSpeakerResponsible = "b_responsible"
    case otherSpeaker = "other_speaker"
    case noResponsibilityAssigned = "no_responsibility_assigned"
}

enum SemanticAssigneeScope: String, Codable, Equatable, Sendable {
    case individual
    case organization
    case unspecified
}

enum SemanticAssigneeBasis: String, Codable, Equatable, Sendable {
    case speakerCommitment = "speaker_commitment"
    case supportedByUtterance = "supported_by_utterance"
    case absentMustStayEmpty = "absent_must_stay_empty"
}

/// A normalized, typed assignee expectation. `valueReference` is an opaque exact reference only;
/// this layer never interprets it as a display name and never performs fuzzy matching.
struct SemanticAssigneeExpectation: Codable, Equatable, Sendable {
    let scope: SemanticAssigneeScope
    let basis: SemanticAssigneeBasis
    let valueReference: String?
    let evidenceUtteranceIDs: [String]

    init(
        scope: SemanticAssigneeScope,
        basis: SemanticAssigneeBasis,
        valueReference: String?,
        evidenceUtteranceIDs: [String]
    ) {
        self.scope = scope
        self.basis = basis
        self.valueReference = valueReference
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
    }

    var canonicalized: SemanticAssigneeExpectation {
        SemanticAssigneeExpectation(
            scope: scope,
            basis: basis,
            valueReference: valueReference,
            evidenceUtteranceIDs: evidenceUtteranceIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case basis
        case valueReference = "value_reference"
        case evidenceUtteranceIDs = "evidence_utterance_ids"
    }
}

enum SemanticDueStatus: String, Codable, Equatable, Sendable {
    case explicit
    case explicitRelative = "explicit_relative"
    case absent
    case unresolved
}

struct SemanticDueExpectation: Codable, Equatable, Sendable {
    let status: SemanticDueStatus
    let value: String?
    let evidenceUtteranceIDs: [String]

    init(status: SemanticDueStatus, value: String?, evidenceUtteranceIDs: [String]) {
        self.status = status
        self.value = value
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
    }

    var canonicalized: SemanticDueExpectation {
        SemanticDueExpectation(status: status, value: value, evidenceUtteranceIDs: evidenceUtteranceIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case value
        case evidenceUtteranceIDs = "evidence_utterance_ids"
    }
}

struct SemanticGoldOutput: Codable, Equatable, Sendable {
    let id: GoldOutputID
    let evidenceUtteranceIDs: [String]
    let inferenceClass: SemanticInferenceClass
    let targetSpeakerResponsibility: SemanticTargetSpeakerResponsibility
    let assignee: SemanticAssigneeExpectation?
    let due: SemanticDueExpectation?

    init(
        id: GoldOutputID,
        evidenceUtteranceIDs: [String],
        inferenceClass: SemanticInferenceClass,
        targetSpeakerResponsibility: SemanticTargetSpeakerResponsibility,
        assignee: SemanticAssigneeExpectation? = nil,
        due: SemanticDueExpectation? = nil
    ) {
        self.id = id
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
        self.inferenceClass = inferenceClass
        self.targetSpeakerResponsibility = targetSpeakerResponsibility
        self.assignee = assignee?.canonicalized
        self.due = due?.canonicalized
    }

    var canonicalized: SemanticGoldOutput {
        SemanticGoldOutput(
            id: id,
            evidenceUtteranceIDs: evidenceUtteranceIDs,
            inferenceClass: inferenceClass,
            targetSpeakerResponsibility: targetSpeakerResponsibility,
            assignee: assignee,
            due: due
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case evidenceUtteranceIDs = "evidence_utterance_ids"
        case inferenceClass = "inference_class"
        case targetSpeakerResponsibility = "target_speaker_responsibility"
        case assignee
        case due
    }
}

/// The output kind is carried by the collection itself. That prevents a record from claiming to be
/// an Action Item while it sits in the Decisions collection.
struct SemanticGoldOutputCollections: Codable, Equatable, Sendable {
    let decisions: [SemanticGoldOutput]
    let actionItems: [SemanticGoldOutput]
    let openQuestions: [SemanticGoldOutput]
    let nextAgenda: [SemanticGoldOutput]

    init(
        decisions: [SemanticGoldOutput],
        actionItems: [SemanticGoldOutput],
        openQuestions: [SemanticGoldOutput],
        nextAgenda: [SemanticGoldOutput]
    ) {
        self.decisions = Self.sorted(decisions)
        self.actionItems = Self.sorted(actionItems)
        self.openQuestions = Self.sorted(openQuestions)
        self.nextAgenda = Self.sorted(nextAgenda)
    }

    var canonicalized: SemanticGoldOutputCollections {
        SemanticGoldOutputCollections(
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            nextAgenda: nextAgenda
        )
    }

    var referencesByKind: [(SemanticScoringOutputKind, SemanticGoldOutput)] {
        decisions.map { (.decision, $0) }
            + actionItems.map { (.actionItem, $0) }
            + openQuestions.map { (.openQuestion, $0) }
            + nextAgenda.map { (.nextAgenda, $0) }
    }

    private static func sorted(_ values: [SemanticGoldOutput]) -> [SemanticGoldOutput] {
        values.map(\.canonicalized).sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case nextAgenda = "next_agenda"
    }
}

enum SemanticForbiddenInferenceBasis: String, Codable, Equatable, Sendable {
    case utterance
    case absenceInWindow = "absence_in_window"
    case reviewMethod = "review_method"
}

/// No claim text is carried. The opaque id, kind, basis, and evidence are enough for a later
/// versioned policy to account for a forbidden output without copying reviewer prose.
struct SemanticForbiddenInference: Codable, Equatable, Sendable {
    let id: String
    let outputKind: SemanticScoringOutputKind
    let basis: SemanticForbiddenInferenceBasis
    let evidenceUtteranceIDs: [String]

    init(
        id: String,
        outputKind: SemanticScoringOutputKind,
        basis: SemanticForbiddenInferenceBasis,
        evidenceUtteranceIDs: [String]
    ) {
        self.id = id
        self.outputKind = outputKind
        self.basis = basis
        self.evidenceUtteranceIDs = evidenceUtteranceIDs.sorted()
    }

    var canonicalized: SemanticForbiddenInference {
        SemanticForbiddenInference(
            id: id,
            outputKind: outputKind,
            basis: basis,
            evidenceUtteranceIDs: evidenceUtteranceIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case outputKind = "output_kind"
        case basis
        case evidenceUtteranceIDs = "evidence_utterance_ids"
    }
}

enum SemanticAmbiguityHandling: String, Codable, Equatable, Sendable {
    case requireExplicitResolution = "require_explicit_resolution"
    case excludeFromMetrics = "exclude_from_metrics"
}

struct SemanticAmbiguityPolicy: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-ambiguity-policy-v0.1"

    let schemaVersion: String
    let handling: SemanticAmbiguityHandling
    let ambiguityIDs: [String]

    init(
        schemaVersion: String = Self.schemaVersion,
        handling: SemanticAmbiguityHandling,
        ambiguityIDs: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.handling = handling
        self.ambiguityIDs = ambiguityIDs.sorted()
    }

    var canonicalized: SemanticAmbiguityPolicy {
        SemanticAmbiguityPolicy(
            schemaVersion: schemaVersion,
            handling: handling,
            ambiguityIDs: ambiguityIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case handling
        case ambiguityIDs = "ambiguity_ids"
    }
}

/// Confirmed semantic gold admitted only after the metadata-only store has authorized its case.
/// It intentionally carries no transcript, output title/body, reviewer note, local path, or domain
/// UUID. Those fields are unnecessary for exact identity validation and create privacy risk. Its
/// own fingerprint is also absent: the index and matching map hash these exact serialized bytes.
struct SemanticScorerInput: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-scorer-input-v0.1"

    let schemaVersion: String
    let status: SemanticScorerInputStatus
    let scorerReady: Bool
    let secondaryReviewComplete: Bool
    let benchmark: String
    let caseID: String
    let split: BenchmarkSplit
    let predictionArtifactHash: String
    let matchingPolicyVersion: String
    let outputs: SemanticGoldOutputCollections
    let forbiddenInferences: [SemanticForbiddenInference]
    let ambiguityPolicy: SemanticAmbiguityPolicy

    init(
        schemaVersion: String = Self.schemaVersion,
        status: SemanticScorerInputStatus,
        scorerReady: Bool,
        secondaryReviewComplete: Bool,
        benchmark: String,
        caseID: String,
        split: BenchmarkSplit,
        predictionArtifactHash: String,
        matchingPolicyVersion: String,
        outputs: SemanticGoldOutputCollections,
        forbiddenInferences: [SemanticForbiddenInference],
        ambiguityPolicy: SemanticAmbiguityPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.scorerReady = scorerReady
        self.secondaryReviewComplete = secondaryReviewComplete
        self.benchmark = benchmark
        self.caseID = caseID
        self.split = split
        self.predictionArtifactHash = predictionArtifactHash
        self.matchingPolicyVersion = matchingPolicyVersion
        self.outputs = outputs.canonicalized
        self.forbiddenInferences = forbiddenInferences
            .map(\.canonicalized)
            .sorted { $0.id < $1.id }
        self.ambiguityPolicy = ambiguityPolicy.canonicalized
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
        case status
        case scorerReady = "scorer_ready"
        case secondaryReviewComplete = "secondary_review_complete"
        case benchmark
        case caseID = "case_id"
        case split
        case predictionArtifactHash = "prediction_artifact_hash"
        case matchingPolicyVersion = "matching_policy_version"
        case outputs
        case forbiddenInferences = "forbidden_inferences"
        case ambiguityPolicy = "ambiguity_policy"
    }
}
