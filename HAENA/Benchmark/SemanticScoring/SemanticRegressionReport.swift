import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum SemanticRegressionReportError: Error, Codable, Equatable, Sendable {
    case duplicateCaseID
    case caseIdentityMismatch
    case schemaVersionMismatch
    case fingerprintMismatch
    case caseLedgerInvariantViolation
    case aggregateReconciliationMismatch
}

struct SemanticRegressionCaseProvenance: Codable, Equatable, Sendable {
    let benchmark: String
    let split: BenchmarkSplit
    let inputSchemaVersion: String
    let accountingSchemaVersion: String
    let metricSchemaVersion: String
    let matchingMapSchemaVersion: String
    let matchingPolicyVersion: String
    let predictionObservationSchemaVersion: String
    let predictionArtifactHash: String
    let goldInputHash: String

    private enum CodingKeys: String, CodingKey {
        case benchmark
        case split
        case inputSchemaVersion = "input_schema_version"
        case accountingSchemaVersion = "accounting_schema_version"
        case metricSchemaVersion = "metric_schema_version"
        case matchingMapSchemaVersion = "matching_map_schema_version"
        case matchingPolicyVersion = "matching_policy_version"
        case predictionObservationSchemaVersion = "prediction_observation_schema_version"
        case predictionArtifactHash = "prediction_artifact_hash"
        case goldInputHash = "gold_input_hash"
    }
}

struct SemanticRegressionCaseFingerprint: Codable, Comparable, Equatable, Sendable {
    let caseID: String
    let predictionArtifactHash: String
    let goldInputHash: String

    static func < (
        lhs: SemanticRegressionCaseFingerprint,
        rhs: SemanticRegressionCaseFingerprint
    ) -> Bool {
        if lhs.caseID != rhs.caseID { return lhs.caseID < rhs.caseID }
        if lhs.predictionArtifactHash != rhs.predictionArtifactHash {
            return lhs.predictionArtifactHash < rhs.predictionArtifactHash
        }
        return lhs.goldInputHash < rhs.goldInputHash
    }

    private enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case predictionArtifactHash = "prediction_artifact_hash"
        case goldInputHash = "gold_input_hash"
    }
}

struct SemanticRegressionSchemaInventory: Codable, Equatable, Sendable {
    let inputSchemaVersions: [String]
    let accountingSchemaVersions: [String]
    let metricSchemaVersions: [String]
    let matchingMapSchemaVersions: [String]
    let matchingPolicyVersions: [String]
    let predictionObservationSchemaVersions: [String]

    private enum CodingKeys: String, CodingKey {
        case inputSchemaVersions = "input_schema_versions"
        case accountingSchemaVersions = "accounting_schema_versions"
        case metricSchemaVersions = "metric_schema_versions"
        case matchingMapSchemaVersions = "matching_map_schema_versions"
        case matchingPolicyVersions = "matching_policy_versions"
        case predictionObservationSchemaVersions = "prediction_observation_schema_versions"
    }
}

struct SemanticRegressionReportProvenance: Codable, Equatable, Sendable {
    let caseFingerprints: [SemanticRegressionCaseFingerprint]
    let schemaInventory: SemanticRegressionSchemaInventory

    private enum CodingKeys: String, CodingKey {
        case caseFingerprints = "case_fingerprints"
        case schemaInventory = "schema_inventory"
    }
}

struct SemanticEvidenceDiscrepancy: Codable, Comparable, Equatable, Sendable {
    let pair: SemanticMatchingPair
    let predictionState: SemanticPredictionEvidenceState
    let predictedUtteranceIDs: [String]
    let goldUtteranceIDs: [String]
    let missingUtteranceIDs: [String]
    let extraUtteranceIDs: [String]
    let ineligibilityReason: SemanticMetricIneligibilityReason?

    init(
        pair: SemanticMatchingPair,
        predictionState: SemanticPredictionEvidenceState,
        predictedUtteranceIDs: [String],
        goldUtteranceIDs: [String],
        missingUtteranceIDs: [String],
        extraUtteranceIDs: [String],
        ineligibilityReason: SemanticMetricIneligibilityReason?
    ) {
        self.pair = pair
        self.predictionState = predictionState
        self.predictedUtteranceIDs = predictedUtteranceIDs.sorted()
        self.goldUtteranceIDs = goldUtteranceIDs.sorted()
        self.missingUtteranceIDs = missingUtteranceIDs.sorted()
        self.extraUtteranceIDs = extraUtteranceIDs.sorted()
        self.ineligibilityReason = ineligibilityReason
    }

    static func < (lhs: SemanticEvidenceDiscrepancy, rhs: SemanticEvidenceDiscrepancy) -> Bool {
        lhs.pair < rhs.pair
    }

    private enum CodingKeys: String, CodingKey {
        case pair
        case predictionState = "prediction_state"
        case predictedUtteranceIDs = "predicted_utterance_ids"
        case goldUtteranceIDs = "gold_utterance_ids"
        case missingUtteranceIDs = "missing_utterance_ids"
        case extraUtteranceIDs = "extra_utterance_ids"
        case ineligibilityReason = "ineligibility_reason"
    }
}

struct SemanticTargetSpeakerBDiscrepancy: Codable, Comparable, Equatable, Sendable {
    let predictionReference: SemanticPredictionReference?
    let goldReference: SemanticGoldReference?
    let predictionState: SemanticPredictionTargetResponsibility?
    let goldState: SemanticTargetSpeakerResponsibility?
    let ineligibilityReason: SemanticMetricIneligibilityReason?

    static func < (
        lhs: SemanticTargetSpeakerBDiscrepancy,
        rhs: SemanticTargetSpeakerBDiscrepancy
    ) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [
            predictionReference?.caseID ?? goldReference?.caseID ?? "",
            predictionReference?.proposalID.uuidString ?? "",
            goldReference?.outputID.rawValue ?? "",
            predictionState?.rawValue ?? "",
            goldState?.rawValue ?? "",
            ineligibilityReason?.rawValue ?? "",
        ].joined(separator: "\u{1F}")
    }

    private enum CodingKeys: String, CodingKey {
        case predictionReference = "prediction_reference"
        case goldReference = "gold_reference"
        case predictionState = "prediction_state"
        case goldState = "gold_state"
        case ineligibilityReason = "ineligibility_reason"
    }
}

enum SemanticAssigneeDiscrepancyDimension: String, Codable, CaseIterable, Sendable {
    case scope
    case basis
    case value
    case evidence
}

struct SemanticAssigneeDiscrepancy: Codable, Comparable, Equatable, Sendable {
    let pair: SemanticMatchingPair
    let inferenceClass: SemanticInferenceClass
    let dimensions: [SemanticAssigneeDiscrepancyDimension]
    let prediction: SemanticPredictionAssigneeObservation
    let gold: SemanticAssigneeExpectation
    let ineligibilityReason: SemanticMetricIneligibilityReason?

    init(
        pair: SemanticMatchingPair,
        inferenceClass: SemanticInferenceClass,
        dimensions: [SemanticAssigneeDiscrepancyDimension],
        prediction: SemanticPredictionAssigneeObservation,
        gold: SemanticAssigneeExpectation,
        ineligibilityReason: SemanticMetricIneligibilityReason?
    ) {
        self.pair = pair
        self.inferenceClass = inferenceClass
        self.dimensions = SemanticAssigneeDiscrepancyDimension.allCases.filter {
            dimensions.contains($0)
        }
        self.prediction = prediction
        self.gold = gold
        self.ineligibilityReason = ineligibilityReason
    }

    static func < (lhs: SemanticAssigneeDiscrepancy, rhs: SemanticAssigneeDiscrepancy) -> Bool {
        lhs.pair < rhs.pair
    }

    private enum CodingKeys: String, CodingKey {
        case pair
        case inferenceClass = "inference_class"
        case dimensions
        case prediction
        case gold
        case ineligibilityReason = "ineligibility_reason"
    }
}

enum SemanticDueDiscrepancyDimension: String, Codable, CaseIterable, Sendable {
    case status
    case value
    case evidence
}

struct SemanticDueDiscrepancy: Codable, Comparable, Equatable, Sendable {
    let pair: SemanticMatchingPair
    let inferenceClass: SemanticInferenceClass
    let dimensions: [SemanticDueDiscrepancyDimension]
    let prediction: SemanticPredictionDueObservation
    let gold: SemanticDueExpectation
    let ineligibilityReason: SemanticMetricIneligibilityReason?

    init(
        pair: SemanticMatchingPair,
        inferenceClass: SemanticInferenceClass,
        dimensions: [SemanticDueDiscrepancyDimension],
        prediction: SemanticPredictionDueObservation,
        gold: SemanticDueExpectation,
        ineligibilityReason: SemanticMetricIneligibilityReason?
    ) {
        self.pair = pair
        self.inferenceClass = inferenceClass
        self.dimensions = SemanticDueDiscrepancyDimension.allCases.filter {
            dimensions.contains($0)
        }
        self.prediction = prediction
        self.gold = gold
        self.ineligibilityReason = ineligibilityReason
    }

    static func < (lhs: SemanticDueDiscrepancy, rhs: SemanticDueDiscrepancy) -> Bool {
        lhs.pair < rhs.pair
    }

    private enum CodingKeys: String, CodingKey {
        case pair
        case inferenceClass = "inference_class"
        case dimensions
        case prediction
        case gold
        case ineligibilityReason = "ineligibility_reason"
    }
}

enum SemanticRegressionMetricArea: String, Codable, CaseIterable, Sendable {
    case evidence
    case targetSpeakerB = "target_speaker_b"
    case assignee
    case due
    case priorStateTransition = "prior_state_transition"
}

struct SemanticCaseIneligibilityRecord: Codable, Comparable, Equatable, Sendable {
    let area: SemanticRegressionMetricArea
    let predictionReference: SemanticPredictionReference?
    let goldReference: SemanticGoldReference?
    let reason: SemanticMetricIneligibilityReason

    static func < (
        lhs: SemanticCaseIneligibilityRecord,
        rhs: SemanticCaseIneligibilityRecord
    ) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [
            String(SemanticRegressionMetricArea.allCases.firstIndex(of: area) ?? 0),
            predictionReference?.caseID ?? goldReference?.caseID ?? "",
            predictionReference?.proposalID.uuidString ?? "",
            goldReference?.outputID.rawValue ?? "",
            reason.rawValue,
        ].joined(separator: "\u{1F}")
    }

    private enum CodingKeys: String, CodingKey {
        case area
        case predictionReference = "prediction_reference"
        case goldReference = "gold_reference"
        case reason
    }
}

struct SemanticRegressionCaseReport: Codable, Equatable, Sendable {
    let caseID: String
    let provenance: SemanticRegressionCaseProvenance
    let matchedPairs: [SemanticMatchingPair]
    let missedGold: [SemanticGoldReference]
    let extraPredictions: [SemanticPredictionReference]
    let duplicatePredictions: [SemanticDuplicatePredictionDeclaration]
    let evidenceDiscrepancies: [SemanticEvidenceDiscrepancy]
    let targetSpeakerBDiscrepancies: [SemanticTargetSpeakerBDiscrepancy]
    let assigneeDiscrepancies: [SemanticAssigneeDiscrepancy]
    let dueDiscrepancies: [SemanticDueDiscrepancy]
    let forbiddenDeclarations: [SemanticForbiddenPredictionDeclaration]
    let ambiguityPolicy: SemanticAmbiguityPolicy
    let ineligibleRecords: [SemanticCaseIneligibilityRecord]
    let metrics: SemanticMetricResult

    init(
        caseID: String,
        provenance: SemanticRegressionCaseProvenance,
        matchedPairs: [SemanticMatchingPair],
        missedGold: [SemanticGoldReference],
        extraPredictions: [SemanticPredictionReference],
        duplicatePredictions: [SemanticDuplicatePredictionDeclaration],
        evidenceDiscrepancies: [SemanticEvidenceDiscrepancy],
        targetSpeakerBDiscrepancies: [SemanticTargetSpeakerBDiscrepancy],
        assigneeDiscrepancies: [SemanticAssigneeDiscrepancy],
        dueDiscrepancies: [SemanticDueDiscrepancy],
        forbiddenDeclarations: [SemanticForbiddenPredictionDeclaration],
        ambiguityPolicy: SemanticAmbiguityPolicy,
        ineligibleRecords: [SemanticCaseIneligibilityRecord],
        metrics: SemanticMetricResult
    ) {
        self.caseID = caseID
        self.provenance = provenance
        self.matchedPairs = matchedPairs.sorted()
        self.missedGold = missedGold.sorted()
        self.extraPredictions = extraPredictions.sorted()
        self.duplicatePredictions = duplicatePredictions.sorted()
        self.evidenceDiscrepancies = evidenceDiscrepancies.sorted()
        self.targetSpeakerBDiscrepancies = targetSpeakerBDiscrepancies.sorted()
        self.assigneeDiscrepancies = assigneeDiscrepancies.sorted()
        self.dueDiscrepancies = dueDiscrepancies.sorted()
        self.forbiddenDeclarations = forbiddenDeclarations.sorted()
        self.ambiguityPolicy = ambiguityPolicy.canonicalized
        self.ineligibleRecords = ineligibleRecords.sorted()
        self.metrics = metrics
    }

    var canonicalized: SemanticRegressionCaseReport {
        SemanticRegressionCaseReport(
            caseID: caseID,
            provenance: provenance,
            matchedPairs: matchedPairs,
            missedGold: missedGold,
            extraPredictions: extraPredictions,
            duplicatePredictions: duplicatePredictions,
            evidenceDiscrepancies: evidenceDiscrepancies,
            targetSpeakerBDiscrepancies: targetSpeakerBDiscrepancies,
            assigneeDiscrepancies: assigneeDiscrepancies,
            dueDiscrepancies: dueDiscrepancies,
            forbiddenDeclarations: forbiddenDeclarations,
            ambiguityPolicy: ambiguityPolicy,
            ineligibleRecords: ineligibleRecords,
            metrics: metrics
        )
    }

    private enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case provenance
        case matchedPairs = "matched_pairs"
        case missedGold = "missed_gold"
        case extraPredictions = "extra_predictions"
        case duplicatePredictions = "duplicate_predictions"
        case evidenceDiscrepancies = "evidence_discrepancies"
        case targetSpeakerBDiscrepancies = "target_speaker_b_discrepancies"
        case assigneeDiscrepancies = "assignee_discrepancies"
        case dueDiscrepancies = "due_discrepancies"
        case forbiddenDeclarations = "forbidden_declarations"
        case ambiguityPolicy = "ambiguity_policy"
        case ineligibleRecords = "ineligible_records"
        case metrics
    }
}

struct SemanticAmbiguityAggregate: Codable, Equatable, Sendable {
    let handling: SemanticAmbiguityHandling
    let caseCount: Int
    let ambiguityRecordCount: Int

    private enum CodingKeys: String, CodingKey {
        case handling
        case caseCount = "case_count"
        case ambiguityRecordCount = "ambiguity_record_count"
    }
}

struct SemanticRegressionAggregate: Codable, Equatable, Sendable {
    let caseCount: Int
    let outputKinds: [SemanticOutputKindMetrics]
    let evidence: SemanticEvidenceMetrics
    let targetSpeakerB: SemanticTargetSpeakerBMetrics
    let actionItemPolicyMetrics: [SemanticInferenceClassMetrics]
    let forbiddenInference: SemanticForbiddenInferenceMetrics
    let ambiguity: [SemanticAmbiguityAggregate]
    let ineligibilityReasonCounts: [SemanticMetricIneligibilityCount]

    private enum CodingKeys: String, CodingKey {
        case caseCount = "case_count"
        case outputKinds = "output_kinds"
        case evidence
        case targetSpeakerB = "target_speaker_b"
        case actionItemPolicyMetrics = "action_item_policy_metrics"
        case forbiddenInference = "forbidden_inference"
        case ambiguity
        case ineligibilityReasonCounts = "ineligibility_reason_counts"
    }
}

/// Shareable deterministic report. Decoding and construction both reconcile provenance and the
/// aggregate against canonical per-case reports, so a stale or hand-edited aggregate fails closed.
struct SemanticRegressionReport: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-regression-report-v0.1"

    let schemaVersion: String
    let provenance: SemanticRegressionReportProvenance
    let caseReports: [SemanticRegressionCaseReport]
    let aggregate: SemanticRegressionAggregate

    init(caseReports: [SemanticRegressionCaseReport]) throws {
        let canonicalCases = caseReports.map(\.canonicalized).sorted { $0.caseID < $1.caseID }
        let aggregate = try SemanticRegressionAggregateBuilder.build(from: canonicalCases)
        try self.init(
            schemaVersion: Self.schemaVersion,
            provenance: Self.makeProvenance(from: canonicalCases),
            caseReports: canonicalCases,
            aggregate: aggregate
        )
    }

    init(
        schemaVersion: String,
        provenance: SemanticRegressionReportProvenance,
        caseReports: [SemanticRegressionCaseReport],
        aggregate: SemanticRegressionAggregate
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw SemanticRegressionReportError.schemaVersionMismatch
        }
        let canonicalCases = caseReports.map(\.canonicalized).sorted { $0.caseID < $1.caseID }
        guard Set(canonicalCases.map(\.caseID)).count == canonicalCases.count else {
            throw SemanticRegressionReportError.duplicateCaseID
        }
        for caseReport in canonicalCases {
            try Self.validate(caseReport)
        }
        guard provenance == Self.makeProvenance(from: canonicalCases) else {
            throw SemanticRegressionReportError.fingerprintMismatch
        }
        let expectedAggregate = try SemanticRegressionAggregateBuilder.build(from: canonicalCases)
        guard aggregate == expectedAggregate else {
            throw SemanticRegressionReportError.aggregateReconciliationMismatch
        }

        self.schemaVersion = schemaVersion
        self.provenance = provenance
        self.caseReports = canonicalCases
        self.aggregate = aggregate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(String.self, forKey: .schemaVersion),
            provenance: container.decode(SemanticRegressionReportProvenance.self, forKey: .provenance),
            caseReports: container.decode([SemanticRegressionCaseReport].self, forKey: .caseReports),
            aggregate: container.decode(SemanticRegressionAggregate.self, forKey: .aggregate)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(caseReports, forKey: .caseReports)
        try container.encode(aggregate, forKey: .aggregate)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    private static func makeProvenance(
        from cases: [SemanticRegressionCaseReport]
    ) -> SemanticRegressionReportProvenance {
        let provenances = cases.map(\.provenance)
        return SemanticRegressionReportProvenance(
            caseFingerprints: cases.map {
                SemanticRegressionCaseFingerprint(
                    caseID: $0.caseID,
                    predictionArtifactHash: $0.provenance.predictionArtifactHash,
                    goldInputHash: $0.provenance.goldInputHash
                )
            }.sorted(),
            schemaInventory: SemanticRegressionSchemaInventory(
                inputSchemaVersions: uniqueSorted(provenances.map(\.inputSchemaVersion)),
                accountingSchemaVersions: uniqueSorted(provenances.map(\.accountingSchemaVersion)),
                metricSchemaVersions: uniqueSorted(provenances.map(\.metricSchemaVersion)),
                matchingMapSchemaVersions: uniqueSorted(provenances.map(\.matchingMapSchemaVersion)),
                matchingPolicyVersions: uniqueSorted(provenances.map(\.matchingPolicyVersion)),
                predictionObservationSchemaVersions: uniqueSorted(
                    provenances.map(\.predictionObservationSchemaVersion)
                )
            )
        )
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func validate(_ report: SemanticRegressionCaseReport) throws {
        let provenance = report.provenance
        guard provenance.split == .development,
              provenance.inputSchemaVersion == SemanticScorerInput.schemaVersion,
              provenance.accountingSchemaVersion == SemanticAccountingResult.schemaVersion,
              provenance.metricSchemaVersion == SemanticMetricResult.schemaVersion,
              provenance.matchingPolicyVersion == SemanticMatchingMap.policyVersion,
              provenance.predictionObservationSchemaVersion
                == SemanticPredictionMetricObservationSet.schemaVersion,
              [
                  SemanticMatchingMap.schemaVersion,
                  SemanticMatchingMap.duplicateSchemaVersion,
                  SemanticMatchingMap.forbiddenInferenceSchemaVersion,
              ].contains(provenance.matchingMapSchemaVersion),
              report.metrics.schemaVersion == provenance.metricSchemaVersion,
              report.metrics.caseID == report.caseID,
              report.metrics.matchingMapSchemaVersion == provenance.matchingMapSchemaVersion,
              report.metrics.predictionObservationSchemaVersion
                == provenance.predictionObservationSchemaVersion,
              report.ambiguityPolicy.schemaVersion == SemanticAmbiguityPolicy.schemaVersion else {
            throw SemanticRegressionReportError.schemaVersionMismatch
        }
        guard SemanticSHA256Digest.isCanonical(provenance.predictionArtifactHash),
              SemanticSHA256Digest.isCanonical(provenance.goldInputHash) else {
            throw SemanticRegressionReportError.fingerprintMismatch
        }

        let predictions = report.matchedPairs.map(\.prediction)
            + report.extraPredictions
            + report.duplicatePredictions.flatMap { [$0.duplicate, $0.canonical] }
            + report.forbiddenDeclarations.map(\.prediction)
            + report.evidenceDiscrepancies.map(\.pair.prediction)
            + report.targetSpeakerBDiscrepancies.compactMap(\.predictionReference)
            + report.assigneeDiscrepancies.map(\.pair.prediction)
            + report.dueDiscrepancies.map(\.pair.prediction)
            + report.ineligibleRecords.compactMap(\.predictionReference)
        guard predictions.allSatisfy({
            $0.caseID == report.caseID
                && $0.artifactFingerprint == provenance.predictionArtifactHash
        }) else {
            throw SemanticRegressionReportError.caseIdentityMismatch
        }

        let gold = report.matchedPairs.map(\.gold)
            + report.missedGold
            + report.evidenceDiscrepancies.map(\.pair.gold)
            + report.targetSpeakerBDiscrepancies.compactMap(\.goldReference)
            + report.assigneeDiscrepancies.map(\.pair.gold)
            + report.dueDiscrepancies.map(\.pair.gold)
            + report.ineligibleRecords.compactMap(\.goldReference)
        guard gold.allSatisfy({
            $0.caseID == report.caseID
                && $0.inputSchemaVersion == provenance.inputSchemaVersion
        }), report.matchedPairs.allSatisfy({ $0.prediction.kind == $0.gold.kind }) else {
            throw SemanticRegressionReportError.caseIdentityMismatch
        }

        let ledgers = report.metrics.outputKinds.map(\.ledger)
        guard ledgers.count == SemanticScoringOutputKind.allCases.count,
              Set(ledgers.map(\.kind)).count == ledgers.count else {
            throw SemanticRegressionReportError.caseLedgerInvariantViolation
        }
        for ledger in ledgers {
            let matched = report.matchedPairs.filter { $0.prediction.kind == ledger.kind }.count
            let extra = report.extraPredictions.filter { $0.kind == ledger.kind }.count
            let missed = report.missedGold.filter { $0.kind == ledger.kind }.count
            let duplicates = report.duplicatePredictions.filter {
                $0.duplicate.kind == ledger.kind
            }.count
            guard ledger.satisfiesAccountingInvariants,
                  ledger.truePositive == matched,
                  ledger.falsePositive == extra,
                  ledger.falseNegative == missed,
                  ledger.predictionTotal == matched + extra,
                  ledger.goldTotal == matched + missed,
                  ledger.duplicatePredictionCount == duplicates else {
                throw SemanticRegressionReportError.caseLedgerInvariantViolation
            }
        }

        let extraSet = Set(report.extraPredictions)
        let predictionTotal = ledgers.reduce(0) { $0 + $1.predictionTotal }
        guard report.duplicatePredictions.allSatisfy({ extraSet.contains($0.duplicate) }),
              report.forbiddenDeclarations.allSatisfy({ extraSet.contains($0.prediction) }),
              report.metrics.forbiddenInference.declaredViolations
                == report.forbiddenDeclarations,
              report.metrics.forbiddenInference.violationPredictionCount
                == report.forbiddenDeclarations.count,
              report.metrics.forbiddenInference.violationRate.numerator
                == report.forbiddenDeclarations.count,
              report.metrics.forbiddenInference.violationRate.denominator
                == predictionTotal else {
            throw SemanticRegressionReportError.caseLedgerInvariantViolation
        }

        let recordedReasons = Dictionary(grouping: report.ineligibleRecords, by: \.reason)
            .mapValues(\.count)
        guard recordedReasons == metricReasonCounts(report.metrics) else {
            throw SemanticRegressionReportError.caseLedgerInvariantViolation
        }
    }

    private static func metricReasonCounts(
        _ metrics: SemanticMetricResult
    ) -> [SemanticMetricIneligibilityReason: Int] {
        var counts: [SemanticMetricIneligibilityReason: Int] = [:]
        func add(_ diagnostics: SemanticMetricSampleDiagnostics) {
            for item in diagnostics.ineligibleSamples {
                counts[item.reason, default: 0] += item.sampleCount
            }
        }
        add(metrics.evidence.diagnostics)
        add(metrics.targetSpeakerB.diagnostics)
        for policy in metrics.actionItemPolicyMetrics {
            add(policy.assignee.diagnostics)
            add(policy.due.diagnostics)
        }
        for exclusion in metrics.scopeExclusions {
            counts[exclusion.reason, default: 0] += 1
        }
        return counts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provenance
        case caseReports = "case_reports"
        case aggregate
    }
}

private enum SemanticRegressionAggregateBuilder {
    static func build(
        from cases: [SemanticRegressionCaseReport]
    ) throws -> SemanticRegressionAggregate {
        let outputKinds = try SemanticScoringOutputKind.allCases.map { kind in
            let ledgers = try cases.map { report -> SemanticOutputAccountingLedger in
                guard let ledger = report.metrics.outputKinds.first(where: { $0.kind == kind })?.ledger,
                      ledger.satisfiesAccountingInvariants else {
                    throw SemanticRegressionReportError.caseLedgerInvariantViolation
                }
                return ledger
            }
            let ledger = SemanticOutputAccountingLedger(
                kind: kind,
                goldTotal: ledgers.reduce(0) { $0 + $1.goldTotal },
                predictionTotal: ledgers.reduce(0) { $0 + $1.predictionTotal },
                truePositive: ledgers.reduce(0) { $0 + $1.truePositive },
                falsePositive: ledgers.reduce(0) { $0 + $1.falsePositive },
                falseNegative: ledgers.reduce(0) { $0 + $1.falseNegative },
                duplicatePredictionCount: ledgers.reduce(0) {
                    $0 + $1.duplicatePredictionCount
                }
            )
            guard ledger.satisfiesAccountingInvariants else {
                throw SemanticRegressionReportError.caseLedgerInvariantViolation
            }
            return SemanticOutputKindMetrics(
                kind: kind,
                ledger: ledger,
                classification: SemanticBinaryMetrics(
                    truePositive: ledger.truePositive,
                    falsePositive: ledger.falsePositive,
                    falseNegative: ledger.falseNegative
                )
            )
        }

        let evidenceMetrics = cases.map(\.metrics.evidence)
        let targetMetrics = cases.map(\.metrics.targetSpeakerB)
        let policyMetrics = SemanticInferenceClass.reportSortOrder.map { inferenceClass in
            let values = cases.compactMap { report in
                report.metrics.actionItemPolicyMetrics.first {
                    $0.inferenceClass == inferenceClass
                }
            }
            return SemanticInferenceClassMetrics(
                inferenceClass: inferenceClass,
                matchedActionItemCount: values.reduce(0) { $0 + $1.matchedActionItemCount },
                assignee: aggregateAssignee(values.map(\.assignee)),
                due: aggregateDue(values.map(\.due))
            )
        }
        let forbiddenDeclarations = cases.flatMap(\.forbiddenDeclarations).sorted()
        let predictionTotal = outputKinds.reduce(0) { $0 + $1.ledger.predictionTotal }

        let ambiguity: [SemanticAmbiguityAggregate] = SemanticAmbiguityHandling.reportSortOrder
            .compactMap { handling in
            let matching = cases.filter { $0.ambiguityPolicy.handling == handling }
            guard !matching.isEmpty else { return nil }
            return SemanticAmbiguityAggregate(
                handling: handling,
                caseCount: matching.count,
                ambiguityRecordCount: matching.reduce(0) {
                    $0 + $1.ambiguityPolicy.ambiguityIDs.count
                }
            )
            }
        let ineligibilityCounts = Dictionary(
            grouping: cases.flatMap(\.ineligibleRecords),
            by: \.reason
        ).mapValues(\.count)

        return SemanticRegressionAggregate(
            caseCount: cases.count,
            outputKinds: outputKinds,
            evidence: SemanticEvidenceMetrics(
                citation: aggregateBinary(evidenceMetrics.map(\.citation)),
                exactEvidenceSetAccuracy: aggregateFraction(
                    evidenceMetrics.map(\.exactEvidenceSetAccuracy),
                    unavailableWhenEmpty: .noEligibleSamples
                ),
                diagnostics: aggregateDiagnostics(evidenceMetrics.map(\.diagnostics))
            ),
            targetSpeakerB: SemanticTargetSpeakerBMetrics(
                responsibility: aggregateBinary(targetMetrics.map(\.responsibility)),
                exactResponsibilityStateAccuracy: aggregateFraction(
                    targetMetrics.map(\.exactResponsibilityStateAccuracy),
                    unavailableWhenEmpty: .noEligibleSamples
                ),
                otherSpeakerPredictionCount: targetMetrics.reduce(0) {
                    $0 + $1.otherSpeakerPredictionCount
                },
                noResponsibilityAssignedPredictionCount: targetMetrics.reduce(0) {
                    $0 + $1.noResponsibilityAssignedPredictionCount
                },
                diagnostics: aggregateDiagnostics(targetMetrics.map(\.diagnostics))
            ),
            actionItemPolicyMetrics: policyMetrics,
            forbiddenInference: SemanticForbiddenInferenceMetrics(
                violationPredictionCount: forbiddenDeclarations.count,
                violationRate: .ratio(
                    numerator: forbiddenDeclarations.count,
                    denominator: predictionTotal,
                    unavailableWhenEmpty: .noPositivePredictions
                ),
                declaredViolations: forbiddenDeclarations
            ),
            ambiguity: ambiguity,
            ineligibilityReasonCounts: SemanticMetricIneligibilityReason.allCases.compactMap {
                reason in
                guard let count = ineligibilityCounts[reason], count > 0 else { return nil }
                return SemanticMetricIneligibilityCount(reason: reason, sampleCount: count)
            }
        )
    }

    private static func aggregateBinary(_ values: [SemanticBinaryMetrics]) -> SemanticBinaryMetrics {
        SemanticBinaryMetrics(
            truePositive: values.reduce(0) { $0 + $1.truePositive },
            falsePositive: values.reduce(0) { $0 + $1.falsePositive },
            falseNegative: values.reduce(0) { $0 + $1.falseNegative }
        )
    }

    private static func aggregateFraction(
        _ values: [SemanticMetricFraction],
        unavailableWhenEmpty: SemanticMetricAvailability
    ) -> SemanticMetricFraction {
        SemanticMetricFraction.ratio(
            numerator: values.reduce(0) { $0 + $1.numerator },
            denominator: values.reduce(0) { $0 + $1.denominator },
            unavailableWhenEmpty: unavailableWhenEmpty
        )
    }

    private static func aggregateDiagnostics(
        _ values: [SemanticMetricSampleDiagnostics]
    ) -> SemanticMetricSampleDiagnostics {
        var reasons: [SemanticMetricIneligibilityReason: Int] = [:]
        for diagnostics in values {
            for item in diagnostics.ineligibleSamples {
                reasons[item.reason, default: 0] += item.sampleCount
            }
        }
        return SemanticMetricSampleDiagnostics(
            eligibleSampleCount: values.reduce(0) { $0 + $1.eligibleSampleCount },
            reasonCounts: reasons
        )
    }

    private static func aggregateAssignee(
        _ values: [SemanticAssigneeMetrics]
    ) -> SemanticAssigneeMetrics {
        SemanticAssigneeMetrics(
            scopeAccuracy: aggregateFraction(
                values.map(\.scopeAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            basisAccuracy: aggregateFraction(
                values.map(\.basisAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            valueReferenceAccuracy: aggregateFraction(
                values.map(\.valueReferenceAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            exactAccuracy: aggregateFraction(
                values.map(\.exactAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            absentMustStayEmptyCompliance: aggregateFraction(
                values.map(\.absentMustStayEmptyCompliance),
                unavailableWhenEmpty: .noEligibleSamples
            ),
            diagnostics: aggregateDiagnostics(values.map(\.diagnostics))
        )
    }

    private static func aggregateDue(_ values: [SemanticDueMetrics]) -> SemanticDueMetrics {
        SemanticDueMetrics(
            statusAccuracy: aggregateFraction(
                values.map(\.statusAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            comparableValueAccuracy: aggregateFraction(
                values.map(\.comparableValueAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            exactAccuracy: aggregateFraction(
                values.map(\.exactAccuracy), unavailableWhenEmpty: .noEligibleSamples
            ),
            absentCompliance: aggregateFraction(
                values.map(\.absentCompliance), unavailableWhenEmpty: .noEligibleSamples
            ),
            diagnostics: aggregateDiagnostics(values.map(\.diagnostics))
        )
    }
}

private extension SemanticInferenceClass {
    static let reportSortOrder: [SemanticInferenceClass] = [
        .explicit,
        .derivedProposal,
        .forbiddenInference,
    ]
}

private extension SemanticAmbiguityHandling {
    static let reportSortOrder: [SemanticAmbiguityHandling] = [
        .requireExplicitResolution,
        .excludeFromMetrics,
    ]
}

/// One authorized scoring pass produces accounting, metrics, and identity-level discrepancies.
/// Report aggregation consumes only these case reports and never reopens scorer payloads.
enum SemanticRegressionReportBuilder {
    static func build(
        from metricCases: [AuthorizedSemanticMetricScoringCase]
    ) throws -> SemanticRegressionReport {
        let caseIDs = metricCases.map(\.scoringCase.input.caseID)
        guard Set(caseIDs).count == caseIDs.count else {
            throw SemanticRegressionReportError.duplicateCaseID
        }
        return try SemanticRegressionReport(
            caseReports: metricCases.map(SemanticRegressionCaseEvaluator.evaluate)
        )
    }
}

private enum SemanticRegressionCaseEvaluator {
    static func evaluate(
        _ metricCase: AuthorizedSemanticMetricScoringCase
    ) -> SemanticRegressionCaseReport {
        let scoringCase = metricCase.scoringCase
        let input = scoringCase.input
        let accounting = SemanticScoringAccountingCore.account(scoringCase)
        let metrics = SemanticScoringMetricCore.measure(metricCase, accounting: accounting)
        let observations = Dictionary(uniqueKeysWithValues: metricCase.predictionObservations.map {
            ($0.predictionReference, $0)
        })
        let goldOutputs = Dictionary(uniqueKeysWithValues: input.outputs.referencesByKind.map {
            kind, output in
            (
                SemanticGoldReference(
                    inputSchemaVersion: input.schemaVersion,
                    caseID: input.caseID,
                    kind: kind,
                    outputID: output.id
                ),
                output
            )
        })

        var evidenceDiscrepancies: [SemanticEvidenceDiscrepancy] = []
        var responsibilityDiscrepancies: [SemanticTargetSpeakerBDiscrepancy] = []
        var assigneeDiscrepancies: [SemanticAssigneeDiscrepancy] = []
        var dueDiscrepancies: [SemanticDueDiscrepancy] = []
        var ineligible: [SemanticCaseIneligibilityRecord] = []

        for pair in accounting.matchedPairs {
            guard let observation = observations[pair.prediction],
                  let gold = goldOutputs[pair.gold] else { continue }
            evaluateEvidence(
                pair: pair,
                observation: observation,
                gold: gold,
                discrepancies: &evidenceDiscrepancies,
                ineligible: &ineligible
            )
            if pair.prediction.kind == .actionItem {
                evaluateResponsibility(
                    prediction: pair.prediction,
                    goldReference: pair.gold,
                    observation: observation,
                    gold: gold,
                    discrepancies: &responsibilityDiscrepancies,
                    ineligible: &ineligible
                )
                evaluateAssignee(
                    pair: pair,
                    observation: observation.assignee,
                    gold: gold,
                    discrepancies: &assigneeDiscrepancies,
                    ineligible: &ineligible
                )
                evaluateDue(
                    pair: pair,
                    observation: observation.due,
                    gold: gold,
                    discrepancies: &dueDiscrepancies,
                    ineligible: &ineligible
                )
            }
        }

        for prediction in accounting.unmatchedPredictions where prediction.kind == .actionItem {
            guard let observation = observations[prediction] else { continue }
            switch observation.targetResponsibility {
            case .targetSpeakerResponsible:
                responsibilityDiscrepancies.append(
                    SemanticTargetSpeakerBDiscrepancy(
                        predictionReference: prediction,
                        goldReference: nil,
                        predictionState: observation.targetResponsibility,
                        goldState: nil,
                        ineligibilityReason: nil
                    )
                )
            case .unresolved:
                let reason = SemanticMetricIneligibilityReason.targetResponsibilityUnresolved
                responsibilityDiscrepancies.append(
                    SemanticTargetSpeakerBDiscrepancy(
                        predictionReference: prediction,
                        goldReference: nil,
                        predictionState: observation.targetResponsibility,
                        goldState: nil,
                        ineligibilityReason: reason
                    )
                )
                ineligible.append(
                    SemanticCaseIneligibilityRecord(
                        area: .targetSpeakerB,
                        predictionReference: prediction,
                        goldReference: nil,
                        reason: reason
                    )
                )
            case .otherSpeaker, .noResponsibilityAssigned:
                break
            }
        }

        for goldReference in accounting.unmatchedGold where goldReference.kind == .actionItem {
            guard goldOutputs[goldReference]?.targetSpeakerResponsibility
                == .targetSpeakerResponsible else { continue }
            responsibilityDiscrepancies.append(
                SemanticTargetSpeakerBDiscrepancy(
                    predictionReference: nil,
                    goldReference: goldReference,
                    predictionState: nil,
                    goldState: .targetSpeakerResponsible,
                    ineligibilityReason: nil
                )
            )
        }

        ineligible.append(
            SemanticCaseIneligibilityRecord(
                area: .priorStateTransition,
                predictionReference: nil,
                goldReference: nil,
                reason: .scorerIneligiblePriorState
            )
        )

        return SemanticRegressionCaseReport(
            caseID: input.caseID,
            provenance: SemanticRegressionCaseProvenance(
                benchmark: input.benchmark,
                split: input.split,
                inputSchemaVersion: input.schemaVersion,
                accountingSchemaVersion: accounting.schemaVersion,
                metricSchemaVersion: metrics.schemaVersion,
                matchingMapSchemaVersion: scoringCase.matchingMap.schemaVersion,
                matchingPolicyVersion: scoringCase.matchingMap.policyVersion,
                predictionObservationSchemaVersion:
                    SemanticPredictionMetricObservationSet.schemaVersion,
                predictionArtifactHash: scoringCase.matchingMap.predictionArtifactHash,
                goldInputHash: scoringCase.matchingMap.goldInputHash
            ),
            matchedPairs: accounting.matchedPairs,
            missedGold: accounting.unmatchedGold,
            extraPredictions: accounting.unmatchedPredictions,
            duplicatePredictions: accounting.declaredDuplicates,
            evidenceDiscrepancies: evidenceDiscrepancies,
            targetSpeakerBDiscrepancies: responsibilityDiscrepancies,
            assigneeDiscrepancies: assigneeDiscrepancies,
            dueDiscrepancies: dueDiscrepancies,
            forbiddenDeclarations: scoringCase.matchingMap.forbiddenPredictions,
            ambiguityPolicy: input.ambiguityPolicy,
            ineligibleRecords: ineligible,
            metrics: metrics
        )
    }

    private static func evaluateEvidence(
        pair: SemanticMatchingPair,
        observation: SemanticPredictionMetricObservation,
        gold: SemanticGoldOutput,
        discrepancies: inout [SemanticEvidenceDiscrepancy],
        ineligible: inout [SemanticCaseIneligibilityRecord]
    ) {
        let expected = Set(gold.evidenceUtteranceIDs)
        switch observation.evidence.state {
        case .unresolved:
            let reason = SemanticMetricIneligibilityReason.evidenceUnresolved
            discrepancies.append(
                SemanticEvidenceDiscrepancy(
                    pair: pair,
                    predictionState: .unresolved,
                    predictedUtteranceIDs: observation.evidence.utteranceIDs,
                    goldUtteranceIDs: gold.evidenceUtteranceIDs,
                    missingUtteranceIDs: gold.evidenceUtteranceIDs,
                    extraUtteranceIDs: observation.evidence.utteranceIDs,
                    ineligibilityReason: reason
                )
            )
            ineligible.append(
                SemanticCaseIneligibilityRecord(
                    area: .evidence,
                    predictionReference: pair.prediction,
                    goldReference: pair.gold,
                    reason: reason
                )
            )
        case .known, .absent:
            let predicted = observation.evidence.state == .known
                ? Set(observation.evidence.utteranceIDs) : []
            guard predicted != expected else { return }
            discrepancies.append(
                SemanticEvidenceDiscrepancy(
                    pair: pair,
                    predictionState: observation.evidence.state,
                    predictedUtteranceIDs: Array(predicted),
                    goldUtteranceIDs: Array(expected),
                    missingUtteranceIDs: Array(expected.subtracting(predicted)),
                    extraUtteranceIDs: Array(predicted.subtracting(expected)),
                    ineligibilityReason: nil
                )
            )
        }
    }

    private static func evaluateResponsibility(
        prediction: SemanticPredictionReference,
        goldReference: SemanticGoldReference,
        observation: SemanticPredictionMetricObservation,
        gold: SemanticGoldOutput,
        discrepancies: inout [SemanticTargetSpeakerBDiscrepancy],
        ineligible: inout [SemanticCaseIneligibilityRecord]
    ) {
        if observation.targetResponsibility == .unresolved {
            let reason = SemanticMetricIneligibilityReason.targetResponsibilityUnresolved
            discrepancies.append(
                SemanticTargetSpeakerBDiscrepancy(
                    predictionReference: prediction,
                    goldReference: goldReference,
                    predictionState: observation.targetResponsibility,
                    goldState: gold.targetSpeakerResponsibility,
                    ineligibilityReason: reason
                )
            )
            ineligible.append(
                SemanticCaseIneligibilityRecord(
                    area: .targetSpeakerB,
                    predictionReference: prediction,
                    goldReference: goldReference,
                    reason: reason
                )
            )
        } else if !observation.targetResponsibility.matchesReport(gold.targetSpeakerResponsibility) {
            discrepancies.append(
                SemanticTargetSpeakerBDiscrepancy(
                    predictionReference: prediction,
                    goldReference: goldReference,
                    predictionState: observation.targetResponsibility,
                    goldState: gold.targetSpeakerResponsibility,
                    ineligibilityReason: nil
                )
            )
        }
    }

    private static func evaluateAssignee(
        pair: SemanticMatchingPair,
        observation: SemanticPredictionAssigneeObservation,
        gold: SemanticGoldOutput,
        discrepancies: inout [SemanticAssigneeDiscrepancy],
        ineligible: inout [SemanticCaseIneligibilityRecord]
    ) {
        guard let expected = gold.assignee else { return }
        let reason: SemanticMetricIneligibilityReason?
        switch observation.state {
        case .unresolved: reason = .assigneeUnresolved
        case .incomparable: reason = .assigneeIncomparable
        case .known, .absent: reason = nil
        }
        if let reason {
            discrepancies.append(
                SemanticAssigneeDiscrepancy(
                    pair: pair,
                    inferenceClass: gold.inferenceClass,
                    dimensions: [],
                    prediction: observation,
                    gold: expected,
                    ineligibilityReason: reason
                )
            )
            ineligible.append(
                SemanticCaseIneligibilityRecord(
                    area: .assignee,
                    predictionReference: pair.prediction,
                    goldReference: pair.gold,
                    reason: reason
                )
            )
            return
        }

        let observedScope: SemanticAssigneeScope? = observation.state == .absent
            ? .unspecified : observation.scope
        let observedBasis: SemanticAssigneeBasis? = observation.state == .absent
            ? .absentMustStayEmpty : observation.basis
        let observedValue = observation.state == .absent ? nil : observation.valueReference
        let observedEvidence = observation.state == .absent ? [] : observation.evidenceUtteranceIDs
        var dimensions: [SemanticAssigneeDiscrepancyDimension] = []
        if observedScope != expected.scope { dimensions.append(.scope) }
        if observedBasis != expected.basis { dimensions.append(.basis) }
        if observedValue != expected.valueReference { dimensions.append(.value) }
        if observedEvidence != expected.evidenceUtteranceIDs { dimensions.append(.evidence) }
        guard !dimensions.isEmpty else { return }
        discrepancies.append(
            SemanticAssigneeDiscrepancy(
                pair: pair,
                inferenceClass: gold.inferenceClass,
                dimensions: dimensions,
                prediction: observation,
                gold: expected,
                ineligibilityReason: nil
            )
        )
    }

    private static func evaluateDue(
        pair: SemanticMatchingPair,
        observation: SemanticPredictionDueObservation,
        gold: SemanticGoldOutput,
        discrepancies: inout [SemanticDueDiscrepancy],
        ineligible: inout [SemanticCaseIneligibilityRecord]
    ) {
        guard let expected = gold.due else { return }
        let reason: SemanticMetricIneligibilityReason?
        if expected.status == .unresolved {
            reason = .goldDueUnresolved
        } else {
            switch observation.status {
            case .unresolved: reason = .predictionDueUnresolved
            case .incomparable: reason = .predictionDueIncomparable
            case .explicit, .explicitRelative, .absent: reason = nil
            }
        }
        if let reason {
            discrepancies.append(
                SemanticDueDiscrepancy(
                    pair: pair,
                    inferenceClass: gold.inferenceClass,
                    dimensions: [],
                    prediction: observation,
                    gold: expected,
                    ineligibilityReason: reason
                )
            )
            ineligible.append(
                SemanticCaseIneligibilityRecord(
                    area: .due,
                    predictionReference: pair.prediction,
                    goldReference: pair.gold,
                    reason: reason
                )
            )
            return
        }

        var dimensions: [SemanticDueDiscrepancyDimension] = []
        if observation.status.goldStatusForReport != expected.status { dimensions.append(.status) }
        if observation.value != expected.value { dimensions.append(.value) }
        if observation.evidenceUtteranceIDs != expected.evidenceUtteranceIDs {
            dimensions.append(.evidence)
        }
        guard !dimensions.isEmpty else { return }
        discrepancies.append(
            SemanticDueDiscrepancy(
                pair: pair,
                inferenceClass: gold.inferenceClass,
                dimensions: dimensions,
                prediction: observation,
                gold: expected,
                ineligibilityReason: nil
            )
        )
    }
}

private extension SemanticPredictionTargetResponsibility {
    func matchesReport(_ gold: SemanticTargetSpeakerResponsibility) -> Bool {
        switch (self, gold) {
        case (.targetSpeakerResponsible, .targetSpeakerResponsible),
             (.otherSpeaker, .otherSpeaker),
             (.noResponsibilityAssigned, .noResponsibilityAssigned):
            true
        default:
            false
        }
    }
}

private extension SemanticPredictionDueStatus {
    var goldStatusForReport: SemanticDueStatus? {
        switch self {
        case .explicit: .explicit
        case .explicitRelative: .explicitRelative
        case .absent: .absent
        case .unresolved, .incomparable: nil
        }
    }
}
