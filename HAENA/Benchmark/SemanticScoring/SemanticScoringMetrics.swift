import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum SemanticMetricAvailability: String, Codable, Equatable, Sendable {
    case available
    case noEligibleSamples = "no_eligible_samples"
    case noPositivePredictions = "no_positive_predictions"
    case noPositiveGold = "no_positive_gold"
    case noPositiveGoldOrPredictions = "no_positive_gold_or_predictions"
}

/// The integer fraction is authoritative. `value` is a convenience projection and is unavailable
/// whenever the denominator is zero; the scorer never serializes NaN or a fabricated zero score.
struct SemanticMetricFraction: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int
    let availability: SemanticMetricAvailability

    var value: Double? {
        guard availability == .available, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    private init(
        numerator: Int,
        denominator: Int,
        availability: SemanticMetricAvailability
    ) {
        self.numerator = numerator
        self.denominator = denominator
        self.availability = availability
    }

    static func ratio(
        numerator: Int,
        denominator: Int,
        unavailableWhenEmpty: SemanticMetricAvailability
    ) -> SemanticMetricFraction {
        precondition(numerator >= 0 && denominator >= 0 && numerator <= denominator)
        return SemanticMetricFraction(
            numerator: numerator,
            denominator: denominator,
            availability: denominator == 0 ? unavailableWhenEmpty : .available
        )
    }
}

enum SemanticMetricIneligibilityReason: String, Codable, CaseIterable, Equatable, Sendable {
    case evidenceUnresolved = "evidence_unresolved"
    case targetResponsibilityUnresolved = "target_responsibility_unresolved"
    case assigneeUnresolved = "assignee_unresolved"
    case assigneeIncomparable = "assignee_incomparable"
    case predictionDueUnresolved = "prediction_due_unresolved"
    case predictionDueIncomparable = "prediction_due_incomparable"
    case goldDueUnresolved = "gold_due_unresolved"
    case scorerIneligiblePriorState = "scorer_ineligible_prior_state"
}

struct SemanticMetricIneligibilityCount: Codable, Equatable, Sendable {
    let reason: SemanticMetricIneligibilityReason
    let sampleCount: Int

    private enum CodingKeys: String, CodingKey {
        case reason
        case sampleCount = "sample_count"
    }
}

struct SemanticMetricSampleDiagnostics: Codable, Equatable, Sendable {
    let eligibleSampleCount: Int
    let ineligibleSampleCount: Int
    let unresolvedSampleCount: Int
    let incomparableSampleCount: Int
    let ineligibleSamples: [SemanticMetricIneligibilityCount]

    fileprivate init(
        eligibleSampleCount: Int,
        reasonCounts: [SemanticMetricIneligibilityReason: Int]
    ) {
        self.eligibleSampleCount = eligibleSampleCount
        ineligibleSampleCount = reasonCounts.values.reduce(0, +)
        unresolvedSampleCount = reasonCounts.reduce(into: 0) { total, pair in
            switch pair.key {
            case .evidenceUnresolved, .targetResponsibilityUnresolved, .assigneeUnresolved,
                 .predictionDueUnresolved, .goldDueUnresolved:
                total += pair.value
            case .assigneeIncomparable, .predictionDueIncomparable,
                 .scorerIneligiblePriorState:
                break
            }
        }
        incomparableSampleCount = reasonCounts.reduce(into: 0) { total, pair in
            switch pair.key {
            case .assigneeIncomparable, .predictionDueIncomparable:
                total += pair.value
            default:
                break
            }
        }
        ineligibleSamples = SemanticMetricIneligibilityReason.allCases.compactMap { reason in
            guard let count = reasonCounts[reason], count > 0 else { return nil }
            return SemanticMetricIneligibilityCount(reason: reason, sampleCount: count)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eligibleSampleCount = "eligible_sample_count"
        case ineligibleSampleCount = "ineligible_sample_count"
        case unresolvedSampleCount = "unresolved_sample_count"
        case incomparableSampleCount = "incomparable_sample_count"
        case ineligibleSamples = "ineligible_samples"
    }
}

struct SemanticBinaryMetrics: Codable, Equatable, Sendable {
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let precision: SemanticMetricFraction
    let recall: SemanticMetricFraction
    let f1: SemanticMetricFraction

    fileprivate init(truePositive: Int, falsePositive: Int, falseNegative: Int) {
        self.truePositive = truePositive
        self.falsePositive = falsePositive
        self.falseNegative = falseNegative
        precision = .ratio(
            numerator: truePositive,
            denominator: truePositive + falsePositive,
            unavailableWhenEmpty: .noPositivePredictions
        )
        recall = .ratio(
            numerator: truePositive,
            denominator: truePositive + falseNegative,
            unavailableWhenEmpty: .noPositiveGold
        )
        f1 = .ratio(
            numerator: 2 * truePositive,
            denominator: 2 * truePositive + falsePositive + falseNegative,
            unavailableWhenEmpty: .noPositiveGoldOrPredictions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case truePositive = "true_positive"
        case falsePositive = "false_positive"
        case falseNegative = "false_negative"
        case precision
        case recall
        case f1
    }
}

struct SemanticOutputKindMetrics: Codable, Equatable, Sendable {
    let kind: SemanticScoringOutputKind
    let ledger: SemanticOutputAccountingLedger
    let classification: SemanticBinaryMetrics
}

struct SemanticEvidenceMetrics: Codable, Equatable, Sendable {
    let citation: SemanticBinaryMetrics
    let exactEvidenceSetAccuracy: SemanticMetricFraction
    let diagnostics: SemanticMetricSampleDiagnostics

    private enum CodingKeys: String, CodingKey {
        case citation
        case exactEvidenceSetAccuracy = "exact_evidence_set_accuracy"
        case diagnostics
    }
}

struct SemanticTargetSpeakerBMetrics: Codable, Equatable, Sendable {
    let responsibility: SemanticBinaryMetrics
    let exactResponsibilityStateAccuracy: SemanticMetricFraction
    let otherSpeakerPredictionCount: Int
    let noResponsibilityAssignedPredictionCount: Int
    let diagnostics: SemanticMetricSampleDiagnostics

    private enum CodingKeys: String, CodingKey {
        case responsibility
        case exactResponsibilityStateAccuracy = "exact_responsibility_state_accuracy"
        case otherSpeakerPredictionCount = "other_speaker_prediction_count"
        case noResponsibilityAssignedPredictionCount = "no_responsibility_assigned_prediction_count"
        case diagnostics
    }
}

struct SemanticAssigneeMetrics: Codable, Equatable, Sendable {
    let scopeAccuracy: SemanticMetricFraction
    let basisAccuracy: SemanticMetricFraction
    let valueReferenceAccuracy: SemanticMetricFraction
    let exactAccuracy: SemanticMetricFraction
    let absentMustStayEmptyCompliance: SemanticMetricFraction
    let diagnostics: SemanticMetricSampleDiagnostics

    private enum CodingKeys: String, CodingKey {
        case scopeAccuracy = "scope_accuracy"
        case basisAccuracy = "basis_accuracy"
        case valueReferenceAccuracy = "value_reference_accuracy"
        case exactAccuracy = "exact_accuracy"
        case absentMustStayEmptyCompliance = "absent_must_stay_empty_compliance"
        case diagnostics
    }
}

struct SemanticDueMetrics: Codable, Equatable, Sendable {
    let statusAccuracy: SemanticMetricFraction
    let comparableValueAccuracy: SemanticMetricFraction
    let exactAccuracy: SemanticMetricFraction
    let absentCompliance: SemanticMetricFraction
    let diagnostics: SemanticMetricSampleDiagnostics

    private enum CodingKeys: String, CodingKey {
        case statusAccuracy = "status_accuracy"
        case comparableValueAccuracy = "comparable_value_accuracy"
        case exactAccuracy = "exact_accuracy"
        case absentCompliance = "absent_compliance"
        case diagnostics
    }
}

struct SemanticInferenceClassMetrics: Codable, Equatable, Sendable {
    let inferenceClass: SemanticInferenceClass
    let matchedActionItemCount: Int
    let assignee: SemanticAssigneeMetrics
    let due: SemanticDueMetrics

    private enum CodingKeys: String, CodingKey {
        case inferenceClass = "inference_class"
        case matchedActionItemCount = "matched_action_item_count"
        case assignee
        case due
    }
}

struct SemanticForbiddenInferenceMetrics: Codable, Equatable, Sendable {
    let violationPredictionCount: Int
    let violationRate: SemanticMetricFraction
    let declaredViolations: [SemanticForbiddenPredictionDeclaration]

    private enum CodingKeys: String, CodingKey {
        case violationPredictionCount = "violation_prediction_count"
        case violationRate = "violation_rate"
        case declaredViolations = "declared_violations"
    }
}

enum SemanticMetricScope: String, Codable, Equatable, Sendable {
    case priorStateTransition = "prior_state_transition"
}

struct SemanticMetricScopeExclusion: Codable, Equatable, Sendable {
    let scope: SemanticMetricScope
    let reason: SemanticMetricIneligibilityReason
}

/// Deterministic, identity-only metric result. It stores integer fractions and finite diagnostics,
/// never prediction/gold text, transcript text, names, UUID domains, reviewer notes, or paths.
struct SemanticMetricResult: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-metric-result-v0.1"

    let schemaVersion: String
    let caseID: String
    let matchingMapSchemaVersion: String
    let predictionObservationSchemaVersion: String
    let outputKinds: [SemanticOutputKindMetrics]
    let evidence: SemanticEvidenceMetrics
    let targetSpeakerB: SemanticTargetSpeakerBMetrics
    let actionItemPolicyMetrics: [SemanticInferenceClassMetrics]
    let forbiddenInference: SemanticForbiddenInferenceMetrics
    let scopeExclusions: [SemanticMetricScopeExclusion]

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case caseID = "case_id"
        case matchingMapSchemaVersion = "matching_map_schema_version"
        case predictionObservationSchemaVersion = "prediction_observation_schema_version"
        case outputKinds = "output_kinds"
        case evidence
        case targetSpeakerB = "target_speaker_b"
        case actionItemPolicyMetrics = "action_item_policy_metrics"
        case forbiddenInference = "forbidden_inference"
        case scopeExclusions = "scope_exclusions"
    }
}

/// Policy-sensitive metrics over an unforgeable, fully authorized case. There is no overload that
/// accepts raw scorer input, a raw matching map, or unvalidated observations.
enum SemanticScoringMetricCore {
    static func measure(_ metricCase: AuthorizedSemanticMetricScoringCase) -> SemanticMetricResult {
        let scoringCase = metricCase.scoringCase
        let accounting = SemanticScoringAccountingCore.account(scoringCase)
        let observations = Dictionary(uniqueKeysWithValues: metricCase.predictionObservations.map {
            ($0.predictionReference, $0)
        })
        let goldOutputs = Dictionary(uniqueKeysWithValues: scoringCase.input.outputs.referencesByKind.map {
            kind, output in
            (
                SemanticGoldReference(
                    inputSchemaVersion: scoringCase.input.schemaVersion,
                    caseID: scoringCase.input.caseID,
                    kind: kind,
                    outputID: output.id
                ),
                output
            )
        })

        let outputKinds = accounting.ledgers.map { ledger in
            SemanticOutputKindMetrics(
                kind: ledger.kind,
                ledger: ledger,
                classification: SemanticBinaryMetrics(
                    truePositive: ledger.truePositive,
                    falsePositive: ledger.falsePositive,
                    falseNegative: ledger.falseNegative
                )
            )
        }

        let evidence = measureEvidence(
            pairs: scoringCase.matchingMap.pairs,
            observations: observations,
            goldOutputs: goldOutputs
        )
        let targetSpeakerB = measureTargetSpeakerB(
            scoringCase: scoringCase,
            observations: observations,
            goldOutputs: goldOutputs
        )
        let policyMetrics = SemanticInferenceClass.metricSortOrder.map { inferenceClass in
            measureActionItemPolicy(
                inferenceClass,
                pairs: scoringCase.matchingMap.pairs,
                observations: observations,
                goldOutputs: goldOutputs
            )
        }

        return SemanticMetricResult(
            schemaVersion: SemanticMetricResult.schemaVersion,
            caseID: scoringCase.input.caseID,
            matchingMapSchemaVersion: scoringCase.matchingMap.schemaVersion,
            predictionObservationSchemaVersion: SemanticPredictionMetricObservationSet.schemaVersion,
            outputKinds: outputKinds,
            evidence: evidence,
            targetSpeakerB: targetSpeakerB,
            actionItemPolicyMetrics: policyMetrics,
            forbiddenInference: SemanticForbiddenInferenceMetrics(
                violationPredictionCount: scoringCase.matchingMap.forbiddenPredictions.count,
                violationRate: .ratio(
                    numerator: scoringCase.matchingMap.forbiddenPredictions.count,
                    denominator: scoringCase.availablePredictions.count,
                    unavailableWhenEmpty: .noPositivePredictions
                ),
                declaredViolations: scoringCase.matchingMap.forbiddenPredictions.sorted()
            ),
            scopeExclusions: [
                SemanticMetricScopeExclusion(
                    scope: .priorStateTransition,
                    reason: .scorerIneligiblePriorState
                ),
            ]
        )
    }

    private static func measureEvidence(
        pairs: [SemanticMatchingPair],
        observations: [SemanticPredictionReference: SemanticPredictionMetricObservation],
        goldOutputs: [SemanticGoldReference: SemanticGoldOutput]
    ) -> SemanticEvidenceMetrics {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var exact = 0
        var eligible = 0
        var reasons: [SemanticMetricIneligibilityReason: Int] = [:]

        for pair in pairs {
            guard let observation = observations[pair.prediction],
                  let gold = goldOutputs[pair.gold] else { continue }
            let predicted: Set<String>
            switch observation.evidence.state {
            case .known:
                predicted = Set(observation.evidence.utteranceIDs)
            case .absent:
                predicted = []
            case .unresolved:
                reasons[.evidenceUnresolved, default: 0] += 1
                continue
            }

            let expected = Set(gold.evidenceUtteranceIDs)
            truePositive += predicted.intersection(expected).count
            falsePositive += predicted.subtracting(expected).count
            falseNegative += expected.subtracting(predicted).count
            exact += predicted == expected ? 1 : 0
            eligible += 1
        }

        return SemanticEvidenceMetrics(
            citation: SemanticBinaryMetrics(
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative
            ),
            exactEvidenceSetAccuracy: .ratio(
                numerator: exact,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            diagnostics: SemanticMetricSampleDiagnostics(
                eligibleSampleCount: eligible,
                reasonCounts: reasons
            )
        )
    }

    private static func measureTargetSpeakerB(
        scoringCase: AuthorizedSemanticScoringCase,
        observations: [SemanticPredictionReference: SemanticPredictionMetricObservation],
        goldOutputs: [SemanticGoldReference: SemanticGoldOutput]
    ) -> SemanticTargetSpeakerBMetrics {
        let actionPairs = scoringCase.matchingMap.pairs.filter { $0.prediction.kind == .actionItem }
        let predictionByGold = Dictionary(uniqueKeysWithValues: actionPairs.map {
            ($0.gold, $0.prediction)
        })
        let actionPredictions = scoringCase.availablePredictions.filter { $0.kind == .actionItem }
        let actionGold = goldOutputs.filter { $0.key.kind == .actionItem }

        var unresolvedPredictions: Set<SemanticPredictionReference> = []
        var predictedPositive: Set<SemanticPredictionReference> = []
        var otherSpeakerCount = 0
        var noResponsibilityCount = 0
        for prediction in actionPredictions {
            guard let observation = observations[prediction] else { continue }
            switch observation.targetResponsibility {
            case .targetSpeakerResponsible:
                predictedPositive.insert(prediction)
            case .otherSpeaker:
                otherSpeakerCount += 1
            case .noResponsibilityAssigned:
                noResponsibilityCount += 1
            case .unresolved:
                unresolvedPredictions.insert(prediction)
            }
        }

        let ineligibleGold = Set(actionGold.keys.filter { goldReference in
            guard let prediction = predictionByGold[goldReference] else { return false }
            return unresolvedPredictions.contains(prediction)
        })
        let eligibleGoldPositive = Set(actionGold.compactMap { reference, output in
            output.targetSpeakerResponsibility == .targetSpeakerResponsible
                && !ineligibleGold.contains(reference) ? reference : nil
        })
        let truePositivePairs = actionPairs.filter { pair in
            predictedPositive.contains(pair.prediction)
                && eligibleGoldPositive.contains(pair.gold)
        }
        let truePositive = truePositivePairs.count
        let falsePositive = predictedPositive.count - truePositive
        let falseNegative = eligibleGoldPositive.count - truePositive

        var exactState = 0
        var eligibleMatched = 0
        for pair in actionPairs where !unresolvedPredictions.contains(pair.prediction) {
            guard let observation = observations[pair.prediction],
                  let gold = actionGold[pair.gold] else { continue }
            eligibleMatched += 1
            if observation.targetResponsibility.matches(gold.targetSpeakerResponsibility) {
                exactState += 1
            }
        }

        let reasons: [SemanticMetricIneligibilityReason: Int] = unresolvedPredictions.isEmpty
            ? [:]
            : [.targetResponsibilityUnresolved: unresolvedPredictions.count]
        return SemanticTargetSpeakerBMetrics(
            responsibility: SemanticBinaryMetrics(
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative
            ),
            exactResponsibilityStateAccuracy: .ratio(
                numerator: exactState,
                denominator: eligibleMatched,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            otherSpeakerPredictionCount: otherSpeakerCount,
            noResponsibilityAssignedPredictionCount: noResponsibilityCount,
            diagnostics: SemanticMetricSampleDiagnostics(
                eligibleSampleCount: eligibleMatched,
                reasonCounts: reasons
            )
        )
    }

    private static func measureActionItemPolicy(
        _ inferenceClass: SemanticInferenceClass,
        pairs: [SemanticMatchingPair],
        observations: [SemanticPredictionReference: SemanticPredictionMetricObservation],
        goldOutputs: [SemanticGoldReference: SemanticGoldOutput]
    ) -> SemanticInferenceClassMetrics {
        let samples = pairs.compactMap { pair -> (SemanticPredictionMetricObservation, SemanticGoldOutput)? in
            guard pair.prediction.kind == .actionItem,
                  let observation = observations[pair.prediction],
                  let gold = goldOutputs[pair.gold],
                  gold.inferenceClass == inferenceClass else { return nil }
            return (observation, gold)
        }
        return SemanticInferenceClassMetrics(
            inferenceClass: inferenceClass,
            matchedActionItemCount: samples.count,
            assignee: measureAssignee(samples),
            due: measureDue(samples)
        )
    }

    private static func measureAssignee(
        _ samples: [(SemanticPredictionMetricObservation, SemanticGoldOutput)]
    ) -> SemanticAssigneeMetrics {
        var scopeCorrect = 0
        var basisCorrect = 0
        var valueCorrect = 0
        var exactCorrect = 0
        var absentCorrect = 0
        var eligible = 0
        var absentEligible = 0
        var reasons: [SemanticMetricIneligibilityReason: Int] = [:]

        for (observation, output) in samples {
            guard let expected = output.assignee else { continue }
            let observed = observation.assignee
            switch observed.state {
            case .unresolved:
                reasons[.assigneeUnresolved, default: 0] += 1
                continue
            case .incomparable:
                reasons[.assigneeIncomparable, default: 0] += 1
                continue
            case .known, .absent:
                break
            }

            eligible += 1
            let observedScope: SemanticAssigneeScope? = observed.state == .absent
                ? .unspecified : observed.scope
            let observedBasis: SemanticAssigneeBasis? = observed.state == .absent
                ? .absentMustStayEmpty : observed.basis
            let observedValue = observed.state == .absent ? nil : observed.valueReference
            let observedEvidence = observed.state == .absent ? [] : observed.evidenceUtteranceIDs

            scopeCorrect += observedScope == expected.scope ? 1 : 0
            basisCorrect += observedBasis == expected.basis ? 1 : 0
            valueCorrect += observedValue == expected.valueReference ? 1 : 0
            exactCorrect += observedScope == expected.scope
                && observedBasis == expected.basis
                && observedValue == expected.valueReference
                && observedEvidence == expected.evidenceUtteranceIDs ? 1 : 0

            if expected.basis == .absentMustStayEmpty {
                absentEligible += 1
                absentCorrect += observed.state == .absent ? 1 : 0
            }
        }

        let diagnostics = SemanticMetricSampleDiagnostics(
            eligibleSampleCount: eligible,
            reasonCounts: reasons
        )
        return SemanticAssigneeMetrics(
            scopeAccuracy: .ratio(
                numerator: scopeCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            basisAccuracy: .ratio(
                numerator: basisCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            valueReferenceAccuracy: .ratio(
                numerator: valueCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            exactAccuracy: .ratio(
                numerator: exactCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            absentMustStayEmptyCompliance: .ratio(
                numerator: absentCorrect,
                denominator: absentEligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            diagnostics: diagnostics
        )
    }

    private static func measureDue(
        _ samples: [(SemanticPredictionMetricObservation, SemanticGoldOutput)]
    ) -> SemanticDueMetrics {
        var statusCorrect = 0
        var valueCorrect = 0
        var exactCorrect = 0
        var absentCorrect = 0
        var eligible = 0
        var valueEligible = 0
        var absentEligible = 0
        var reasons: [SemanticMetricIneligibilityReason: Int] = [:]

        for (observation, output) in samples {
            guard let expected = output.due else { continue }
            if expected.status == .unresolved {
                reasons[.goldDueUnresolved, default: 0] += 1
                continue
            }
            let observed = observation.due
            switch observed.status {
            case .unresolved:
                reasons[.predictionDueUnresolved, default: 0] += 1
                continue
            case .incomparable:
                reasons[.predictionDueIncomparable, default: 0] += 1
                continue
            case .explicit, .explicitRelative, .absent:
                break
            }

            eligible += 1
            let observedStatus = observed.status.goldStatus
            statusCorrect += observedStatus == expected.status ? 1 : 0
            if expected.status == .explicit || expected.status == .explicitRelative {
                valueEligible += 1
                valueCorrect += observed.value == expected.value ? 1 : 0
            }
            exactCorrect += observedStatus == expected.status
                && observed.value == expected.value
                && observed.evidenceUtteranceIDs == expected.evidenceUtteranceIDs ? 1 : 0

            if expected.status == .absent {
                absentEligible += 1
                absentCorrect += observed.status == .absent ? 1 : 0
            }
        }

        return SemanticDueMetrics(
            statusAccuracy: .ratio(
                numerator: statusCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            comparableValueAccuracy: .ratio(
                numerator: valueCorrect,
                denominator: valueEligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            exactAccuracy: .ratio(
                numerator: exactCorrect,
                denominator: eligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            absentCompliance: .ratio(
                numerator: absentCorrect,
                denominator: absentEligible,
                unavailableWhenEmpty: .noEligibleSamples
            ),
            diagnostics: SemanticMetricSampleDiagnostics(
                eligibleSampleCount: eligible,
                reasonCounts: reasons
            )
        )
    }
}

private extension SemanticPredictionTargetResponsibility {
    func matches(_ gold: SemanticTargetSpeakerResponsibility) -> Bool {
        switch (self, gold) {
        case (.targetSpeakerResponsible, .targetSpeakerResponsible),
             (.otherSpeaker, .otherSpeaker),
             (.noResponsibilityAssigned, .noResponsibilityAssigned):
            return true
        default:
            return false
        }
    }
}

private extension SemanticPredictionDueStatus {
    var goldStatus: SemanticDueStatus? {
        switch self {
        case .explicit: .explicit
        case .explicitRelative: .explicitRelative
        case .absent: .absent
        case .unresolved, .incomparable: nil
        }
    }
}

private extension SemanticInferenceClass {
    static let metricSortOrder: [SemanticInferenceClass] = [
        .explicit,
        .derivedProposal,
        .forbiddenInference,
    ]
}
