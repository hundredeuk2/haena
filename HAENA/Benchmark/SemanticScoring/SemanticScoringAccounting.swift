import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Per-kind integer accounting. Ratio metrics and unavailable-value policy are intentionally
/// deferred; this ledger preserves their exact future numerators and denominators.
struct SemanticOutputAccountingLedger: Codable, Equatable, Sendable {
    let kind: SemanticScoringOutputKind
    let goldTotal: Int
    let predictionTotal: Int
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let duplicatePredictionCount: Int

    var satisfiesAccountingInvariants: Bool {
        truePositive + falseNegative == goldTotal
            && truePositive + falsePositive == predictionTotal
            && duplicatePredictionCount <= falsePositive
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case goldTotal = "gold_total"
        case predictionTotal = "prediction_total"
        case truePositive = "true_positive"
        case falsePositive = "false_positive"
        case falseNegative = "false_negative"
        case duplicatePredictionCount = "duplicate_prediction_count"
    }
}

/// Auditable scorer output containing typed identities only. It never copies prediction or gold
/// titles, bodies, transcript text, evidence text, reviewer notes, or filesystem paths.
struct SemanticAccountingResult: Codable, Equatable, Sendable {
    static let schemaVersion = "haena-semantic-accounting-result-v0.1"

    let schemaVersion: String
    let caseID: String
    let matchingMapSchemaVersion: String
    let matchedPairs: [SemanticMatchingPair]
    let unmatchedPredictions: [SemanticPredictionReference]
    let unmatchedGold: [SemanticGoldReference]
    let declaredDuplicates: [SemanticDuplicatePredictionDeclaration]
    let ledgers: [SemanticOutputAccountingLedger]

    init(
        schemaVersion: String = Self.schemaVersion,
        caseID: String,
        matchingMapSchemaVersion: String,
        matchedPairs: [SemanticMatchingPair],
        unmatchedPredictions: [SemanticPredictionReference],
        unmatchedGold: [SemanticGoldReference],
        declaredDuplicates: [SemanticDuplicatePredictionDeclaration],
        ledgers: [SemanticOutputAccountingLedger]
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.matchingMapSchemaVersion = matchingMapSchemaVersion
        self.matchedPairs = matchedPairs.sorted(by: Self.pairComesBefore)
        self.unmatchedPredictions = unmatchedPredictions.sorted(by: Self.predictionComesBefore)
        self.unmatchedGold = unmatchedGold.sorted(by: Self.goldComesBefore)
        self.declaredDuplicates = declaredDuplicates.sorted(by: Self.duplicateComesBefore)
        self.ledgers = ledgers.sorted { $0.kind.accountingSortOrder < $1.kind.accountingSortOrder }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func pairComesBefore(
        _ lhs: SemanticMatchingPair,
        _ rhs: SemanticMatchingPair
    ) -> Bool {
        if lhs.gold.kind != rhs.gold.kind {
            return lhs.gold.kind.accountingSortOrder < rhs.gold.kind.accountingSortOrder
        }
        return lhs < rhs
    }

    private static func predictionComesBefore(
        _ lhs: SemanticPredictionReference,
        _ rhs: SemanticPredictionReference
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.accountingSortOrder < rhs.kind.accountingSortOrder
        }
        return lhs < rhs
    }

    private static func goldComesBefore(
        _ lhs: SemanticGoldReference,
        _ rhs: SemanticGoldReference
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.accountingSortOrder < rhs.kind.accountingSortOrder
        }
        return lhs < rhs
    }

    private static func duplicateComesBefore(
        _ lhs: SemanticDuplicatePredictionDeclaration,
        _ rhs: SemanticDuplicatePredictionDeclaration
    ) -> Bool {
        if lhs.duplicate.kind != rhs.duplicate.kind {
            return lhs.duplicate.kind.accountingSortOrder < rhs.duplicate.kind.accountingSortOrder
        }
        return lhs < rhs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case caseID = "case_id"
        case matchingMapSchemaVersion = "matching_map_schema_version"
        case matchedPairs = "matched_pairs"
        case unmatchedPredictions = "unmatched_predictions"
        case unmatchedGold = "unmatched_gold"
        case declaredDuplicates = "declared_duplicates"
        case ledgers
    }
}

/// Deterministic identity accounting. The only entry point requires a capability constructed after
/// authorization and payload verification; there is no overload accepting raw input or raw maps.
enum SemanticScoringAccountingCore {
    static func account(_ scoringCase: AuthorizedSemanticScoringCase) -> SemanticAccountingResult {
        let predictions = Set(scoringCase.availablePredictions)
        let gold = Set(scoringCase.input.outputs.referencesByKind.map { kind, output in
            SemanticGoldReference(
                inputSchemaVersion: scoringCase.input.schemaVersion,
                caseID: scoringCase.input.caseID,
                kind: kind,
                outputID: output.id
            )
        })
        let pairs = scoringCase.matchingMap.pairs
        let pairedPredictions = Set(pairs.map(\.prediction))
        let pairedGold = Set(pairs.map(\.gold))
        let duplicates = scoringCase.matchingMap.duplicatePredictions

        let ledgers = SemanticScoringOutputKind.allCases.map { kind in
            let goldTotal = gold.filter { $0.kind == kind }.count
            let predictionTotal = predictions.filter { $0.kind == kind }.count
            let truePositive = pairs.filter { $0.prediction.kind == kind }.count
            let falsePositive = predictionTotal - truePositive
            let falseNegative = goldTotal - truePositive
            let duplicatePredictionCount = duplicates.filter { $0.duplicate.kind == kind }.count
            return SemanticOutputAccountingLedger(
                kind: kind,
                goldTotal: goldTotal,
                predictionTotal: predictionTotal,
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative,
                duplicatePredictionCount: duplicatePredictionCount
            )
        }

        return SemanticAccountingResult(
            caseID: scoringCase.input.caseID,
            matchingMapSchemaVersion: scoringCase.matchingMap.schemaVersion,
            matchedPairs: pairs,
            unmatchedPredictions: Array(predictions.subtracting(pairedPredictions)),
            unmatchedGold: Array(gold.subtracting(pairedGold)),
            declaredDuplicates: duplicates,
            ledgers: ledgers
        )
    }
}

private extension SemanticScoringOutputKind {
    var accountingSortOrder: Int {
        switch self {
        case .decision: 0
        case .actionItem: 1
        case .openQuestion: 2
        case .nextAgenda: 3
        }
    }
}
