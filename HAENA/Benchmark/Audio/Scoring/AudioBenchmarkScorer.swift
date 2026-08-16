import Foundation

/// Deterministic v0 scorer for provider-normalized, timestamped speaker transcripts.
///
/// Contract highlights:
/// - NFC normalization; Unicode whitespace and punctuation removed before Character-level CER.
/// - Speaker labels are matched one-to-one by maximum time overlap only. Text and label names never
///   contribute to the objective; sorted-label lexical order breaks equal-score ties.
/// - DER uses a zero-second collar. Reference and prediction overlap are rejected because the v0
///   corpus has no overlap labels and silently flattening overlapping speech would be incorrect.
/// - Times outside the clip are rejected rather than clamped.
enum AudioBenchmarkScorer {
    static func score(
        prediction: PredictedTranscript,
        reference: AudioBenchmarkReferenceTranscript
    ) throws -> AudioBenchmarkScore {
        try validate(prediction: prediction, reference: reference)

        let predictedLabels = Array(Set(prediction.segments.map(\.predictedSpeakerLabel))).sorted()
        let referenceLabels = Array(Set(reference.segments.map(\.speakerLabel))).sorted()
        let overlapWeights = try overlapMatrix(
            predictedLabels: predictedLabels,
            referenceLabels: referenceLabels,
            predictionSegments: prediction.segments,
            referenceSegments: reference.segments
        )
        let mapping = try optimalSpeakerMapping(
            predictedLabels: predictedLabels,
            referenceLabels: referenceLabels,
            weights: overlapWeights
        )

        let referenceText = normalizedCharacters(
            concatenatedReferenceText(reference.segments)
        )
        let predictionText = normalizedCharacters(
            concatenatedPredictionText(prediction.segments)
        )
        let cer: AudioBenchmarkMetricValue
        if referenceText.isEmpty {
            cer = .unavailable(.emptyReferenceText)
        } else {
            let distance = levenshteinDistance(referenceText, predictionText)
            cer = .measured(Double(distance) / Double(referenceText.count))
        }

        let timeMetrics = try calculateTimeMetrics(
            predictionSegments: prediction.segments,
            referenceSegments: reference.segments,
            mapping: mapping,
            targetSpeakerLabel: reference.targetSpeakerLabel
        )
        let speakerAttributedCER = speakerAttributedCER(
            predictionSegments: prediction.segments,
            referenceSegments: reference.segments,
            referenceLabels: referenceLabels,
            mapping: mapping
        )

        let realTimeFactor = prediction.processingDurationSeconds / prediction.audioDurationSeconds
        guard realTimeFactor.isFinite else {
            throw AudioBenchmarkScoringError(code: .arithmeticOverflow)
        }

        return AudioBenchmarkScore(
            speakerMapping: mapping,
            cer: cer,
            speakerCountError: predictedLabels.count - referenceLabels.count,
            der: timeMetrics.der,
            speakerAttributionAccuracy: timeMetrics.attributionAccuracy,
            targetSpeakerBF1: timeMetrics.targetF1,
            speakerAttributedCER: speakerAttributedCER,
            realTimeFactor: .measured(realTimeFactor)
        )
    }

    // MARK: Validation

    private static func validate(
        prediction: PredictedTranscript,
        reference: AudioBenchmarkReferenceTranscript
    ) throws {
        guard prediction.audioDurationSeconds.isFinite, prediction.audioDurationSeconds > 0 else {
            throw AudioBenchmarkScoringError(code: .predictionAudioDurationInvalid)
        }
        guard reference.audioDurationSeconds.isFinite, reference.audioDurationSeconds > 0 else {
            throw AudioBenchmarkScoringError(code: .referenceAudioDurationInvalid)
        }
        guard prediction.audioDurationSeconds == reference.audioDurationSeconds else {
            throw AudioBenchmarkScoringError(code: .audioDurationMismatch)
        }
        guard prediction.processingDurationSeconds.isFinite,
              prediction.processingDurationSeconds >= 0 else {
            throw AudioBenchmarkScoringError(code: .processingDurationInvalid)
        }
        guard !prediction.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioBenchmarkScoringError(code: .providerIdentifierEmpty)
        }
        guard !prediction.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioBenchmarkScoringError(code: .modelIdentifierEmpty)
        }
        guard !reference.targetSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioBenchmarkScoringError(code: .targetSpeakerLabelEmpty)
        }

        try validatePredictionSegments(prediction.segments, clipDuration: prediction.audioDurationSeconds)
        try validateReferenceSegments(reference.segments, clipDuration: reference.audioDurationSeconds)
    }

    private static func validatePredictionSegments(
        _ segments: [PredictedSegment],
        clipDuration: Double
    ) throws {
        for (index, segment) in segments.enumerated() {
            try validateSegment(
                start: segment.startTimeSeconds,
                end: segment.endTimeSeconds,
                speaker: segment.predictedSpeakerLabel,
                text: segment.text,
                clipDuration: clipDuration,
                index: index
            )
        }
        try rejectOverlap(
            segments.enumerated().map { ($0.offset, $0.element.startTimeSeconds, $0.element.endTimeSeconds) },
            code: .overlappingPredictionSegments
        )
    }

    private static func validateReferenceSegments(
        _ segments: [AudioBenchmarkReferenceSegment],
        clipDuration: Double
    ) throws {
        for (index, segment) in segments.enumerated() {
            try validateSegment(
                start: segment.startTimeSeconds,
                end: segment.endTimeSeconds,
                speaker: segment.speakerLabel,
                text: segment.textNormalized,
                clipDuration: clipDuration,
                index: index
            )
        }
        try rejectOverlap(
            segments.enumerated().map { ($0.offset, $0.element.startTimeSeconds, $0.element.endTimeSeconds) },
            code: .overlappingReferenceSegments
        )
    }

    private static func validateSegment(
        start: Double,
        end: Double,
        speaker: String,
        text: String,
        clipDuration: Double,
        index: Int
    ) throws {
        guard start.isFinite, end.isFinite else {
            throw AudioBenchmarkScoringError(code: .segmentTimeNotFinite, segmentIndex: index)
        }
        guard start >= 0, end >= 0 else {
            throw AudioBenchmarkScoringError(code: .segmentTimeNegative, segmentIndex: index)
        }
        guard end > start else {
            throw AudioBenchmarkScoringError(code: .segmentEndNotAfterStart, segmentIndex: index)
        }
        guard end <= clipDuration else {
            throw AudioBenchmarkScoringError(code: .segmentOutsideClip, segmentIndex: index)
        }
        guard !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioBenchmarkScoringError(code: .segmentSpeakerLabelEmpty, segmentIndex: index)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioBenchmarkScoringError(code: .segmentTextEmpty, segmentIndex: index)
        }
    }

    private static func rejectOverlap(
        _ indexedTimes: [(index: Int, start: Double, end: Double)],
        code: AudioBenchmarkScoringDiagnosticCode
    ) throws {
        let sorted = indexedTimes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.index < $1.index
        }
        guard sorted.count >= 2 else { return }
        for pairIndex in 1..<sorted.count {
            let previous = sorted[pairIndex - 1]
            let current = sorted[pairIndex]
            if current.start < previous.end {
                throw AudioBenchmarkScoringError(
                    code: code,
                    segmentIndex: previous.index,
                    conflictingSegmentIndex: current.index
                )
            }
        }
    }

    // MARK: Speaker matching

    private static func overlapMatrix(
        predictedLabels: [String],
        referenceLabels: [String],
        predictionSegments: [PredictedSegment],
        referenceSegments: [AudioBenchmarkReferenceSegment]
    ) throws -> [[Double]] {
        var predictedIndex: [String: Int] = [:]
        for (index, label) in predictedLabels.enumerated() { predictedIndex[label] = index }
        var referenceIndex: [String: Int] = [:]
        for (index, label) in referenceLabels.enumerated() { referenceIndex[label] = index }
        var weights = Array(
            repeating: Array(repeating: 0.0, count: referenceLabels.count),
            count: predictedLabels.count
        )

        for predicted in predictionSegments {
            for reference in referenceSegments {
                let overlap = min(predicted.endTimeSeconds, reference.endTimeSeconds)
                    - max(predicted.startTimeSeconds, reference.startTimeSeconds)
                guard overlap > 0,
                      let predictedLabelIndex = predictedIndex[predicted.predictedSpeakerLabel],
                      let referenceLabelIndex = referenceIndex[reference.speakerLabel] else {
                    continue
                }
                weights[predictedLabelIndex][referenceLabelIndex] = try checkedAdd(
                    weights[predictedLabelIndex][referenceLabelIndex],
                    overlap
                )
            }
        }
        return weights
    }

    /// Lexicographically smallest assignment vector among all maximum-overlap matchings.
    ///
    /// Predicted and reference labels are already sorted. For each predicted label, real reference
    /// labels are attempted in lexical order and the unmatched sentinel is attempted last. A choice
    /// is retained only when a maximum-weight matching remains possible for the suffix.
    private static func optimalSpeakerMapping(
        predictedLabels: [String],
        referenceLabels: [String],
        weights: [[Double]]
    ) throws -> [String: String] {
        guard !predictedLabels.isEmpty, !referenceLabels.isEmpty else { return [:] }
        let optimum = try maximumMatchingWeight(weights)
        var fixedWeight = 0.0
        var usedReferenceIndices: Set<Int> = []
        var mapping: [String: String] = [:]

        for predictedIndex in predictedLabels.indices {
            let availableReferences = referenceLabels.indices.filter {
                !usedReferenceIndices.contains($0) && weights[predictedIndex][$0] > 0
            }
            let candidates: [Int?] = availableReferences.map(Optional.some) + [nil]
            var selected: Int?
            var foundFeasibleChoice = false

            for candidate in candidates {
                var candidateUsed = usedReferenceIndices
                var candidateWeight = fixedWeight
                if let candidate {
                    candidateUsed.insert(candidate)
                    candidateWeight = try checkedAdd(candidateWeight, weights[predictedIndex][candidate])
                }

                let remainingPredicted = Array(weights.indices.dropFirst(predictedIndex + 1))
                let remainingReferences = referenceLabels.indices.filter { !candidateUsed.contains($0) }
                let remainingWeights = remainingPredicted.map { row in
                    remainingReferences.map { weights[row][$0] }
                }
                let suffixWeight = try maximumMatchingWeight(remainingWeights)
                let possibleTotal = try checkedAdd(candidateWeight, suffixWeight)
                if approximatelyEqual(possibleTotal, optimum) {
                    selected = candidate
                    fixedWeight = candidateWeight
                    usedReferenceIndices = candidateUsed
                    foundFeasibleChoice = true
                    break
                }
            }

            // A dummy unmatched column always makes one candidate feasible. Treat a numerical
            // violation of that invariant as arithmetic failure rather than inventing a mapping.
            guard foundFeasibleChoice else {
                throw AudioBenchmarkScoringError(code: .arithmeticOverflow)
            }
            if let selected {
                mapping[predictedLabels[predictedIndex]] = referenceLabels[selected]
            }
        }
        return mapping
    }

    /// Maximum-weight rectangular assignment with one private zero-weight dummy column per row.
    /// The Hungarian implementation is polynomial and therefore does not impose an arbitrary
    /// maximum speaker count. Only the objective is used; lexical tie-breaking is layered above.
    private static func maximumMatchingWeight(_ weights: [[Double]]) throws -> Double {
        let rowCount = weights.count
        guard rowCount > 0 else { return 0 }
        let referenceColumnCount = weights.first?.count ?? 0
        guard referenceColumnCount > 0 else { return 0 }
        let columnCount = referenceColumnCount + rowCount
        var rowPotential = Array(repeating: 0.0, count: rowCount + 1)
        var columnPotential = Array(repeating: 0.0, count: columnCount + 1)
        var rowForColumn = Array(repeating: 0, count: columnCount + 1)
        var previousColumn = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            rowForColumn[0] = row
            var currentColumn = 0
            var minimumReducedCost = Array(repeating: Double.infinity, count: columnCount + 1)
            var usedColumn = Array(repeating: false, count: columnCount + 1)

            repeat {
                usedColumn[currentColumn] = true
                let currentRow = rowForColumn[currentColumn]
                var delta = Double.infinity
                var nextColumn = 0
                for column in 1...columnCount where !usedColumn[column] {
                    let weight = column <= referenceColumnCount
                        ? weights[currentRow - 1][column - 1]
                        : 0
                    let cost = -weight
                    let reducedCost = cost - rowPotential[currentRow] - columnPotential[column]
                    if reducedCost < minimumReducedCost[column] {
                        minimumReducedCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if minimumReducedCost[column] < delta
                        || (minimumReducedCost[column] == delta && column < nextColumn) {
                        delta = minimumReducedCost[column]
                        nextColumn = column
                    }
                }
                guard delta.isFinite else {
                    throw AudioBenchmarkScoringError(code: .arithmeticOverflow)
                }
                for column in 0...columnCount {
                    if usedColumn[column] {
                        rowPotential[rowForColumn[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimumReducedCost[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while rowForColumn[currentColumn] != 0

            repeat {
                let precedingColumn = previousColumn[currentColumn]
                rowForColumn[currentColumn] = rowForColumn[precedingColumn]
                currentColumn = precedingColumn
            } while currentColumn != 0
        }

        var total = 0.0
        for column in 1...referenceColumnCount {
            let assignedRow = rowForColumn[column]
            if assignedRow > 0 {
                total = try checkedAdd(total, weights[assignedRow - 1][column - 1])
            }
        }
        return total
    }

    // MARK: Time metrics

    private struct TimeMetrics {
        let der: AudioBenchmarkMetricValue
        let attributionAccuracy: AudioBenchmarkMetricValue
        let targetF1: AudioBenchmarkMetricValue
    }

    private static func calculateTimeMetrics(
        predictionSegments: [PredictedSegment],
        referenceSegments: [AudioBenchmarkReferenceSegment],
        mapping: [String: String],
        targetSpeakerLabel: String
    ) throws -> TimeMetrics {
        let boundaries = Set(
            predictionSegments.flatMap { [$0.startTimeSeconds, $0.endTimeSeconds] }
                + referenceSegments.flatMap { [$0.startTimeSeconds, $0.endTimeSeconds] }
        ).sorted()
        var referenceSpeech = 0.0
        var miss = 0.0
        var falseAlarm = 0.0
        var confusion = 0.0
        var correctlyAttributed = 0.0
        var targetTruePositive = 0.0
        var targetFalsePositive = 0.0
        var targetFalseNegative = 0.0

        if boundaries.count >= 2 {
            for boundaryIndex in 0..<(boundaries.count - 1) {
                let start = boundaries[boundaryIndex]
                let end = boundaries[boundaryIndex + 1]
                let duration = end - start
                guard duration > 0 else { continue }
                let predicted = predictionSegments.first {
                    $0.startTimeSeconds <= start && $0.endTimeSeconds >= end
                }
                let reference = referenceSegments.first {
                    $0.startTimeSeconds <= start && $0.endTimeSeconds >= end
                }
                let mappedPrediction = predicted.flatMap { mapping[$0.predictedSpeakerLabel] }

                if reference != nil {
                    referenceSpeech = try checkedAdd(referenceSpeech, duration)
                }
                switch (reference, predicted) {
                case (.some, nil):
                    miss = try checkedAdd(miss, duration)
                case (nil, .some):
                    falseAlarm = try checkedAdd(falseAlarm, duration)
                case let (.some(reference), .some):
                    if mappedPrediction == reference.speakerLabel {
                        correctlyAttributed = try checkedAdd(correctlyAttributed, duration)
                    } else {
                        confusion = try checkedAdd(confusion, duration)
                    }
                case (nil, nil):
                    break
                }

                let referenceIsTarget = reference?.speakerLabel == targetSpeakerLabel
                let predictionIsTarget = mappedPrediction == targetSpeakerLabel
                if referenceIsTarget && predictionIsTarget {
                    targetTruePositive = try checkedAdd(targetTruePositive, duration)
                } else if referenceIsTarget {
                    targetFalseNegative = try checkedAdd(targetFalseNegative, duration)
                } else if predictionIsTarget {
                    targetFalsePositive = try checkedAdd(targetFalsePositive, duration)
                }
            }
        }

        let der: AudioBenchmarkMetricValue
        let attribution: AudioBenchmarkMetricValue
        if referenceSpeech == 0 {
            der = .unavailable(.noReferenceSpeech)
            attribution = .unavailable(.noReferenceSpeech)
        } else {
            let errorDuration = try checkedAdd(try checkedAdd(miss, falseAlarm), confusion)
            der = .measured(errorDuration / referenceSpeech)
            attribution = .measured(correctlyAttributed / referenceSpeech)
        }

        let targetPresent = referenceSegments.contains { $0.speakerLabel == targetSpeakerLabel }
        let targetF1: AudioBenchmarkMetricValue
        if !targetPresent {
            targetF1 = .unavailable(.targetSpeakerAbsent)
        } else if targetTruePositive == 0 {
            // This includes the required "no prediction mapped to B" case.
            targetF1 = .measured(0)
        } else {
            let scale = max(targetTruePositive, max(targetFalsePositive, targetFalseNegative))
            let scaledTruePositive = targetTruePositive / scale
            let denominator = (2 * scaledTruePositive)
                + (targetFalsePositive / scale)
                + (targetFalseNegative / scale)
            targetF1 = .measured((2 * scaledTruePositive) / denominator)
        }

        return TimeMetrics(der: der, attributionAccuracy: attribution, targetF1: targetF1)
    }

    // MARK: Text metrics

    private static func speakerAttributedCER(
        predictionSegments: [PredictedSegment],
        referenceSegments: [AudioBenchmarkReferenceSegment],
        referenceLabels: [String],
        mapping: [String: String]
    ) -> AudioBenchmarkMetricValue {
        var referenceCharacterCount = 0
        var editCount = 0

        for referenceLabel in referenceLabels {
            let referenceText = normalizedCharacters(
                concatenatedReferenceText(referenceSegments.filter { $0.speakerLabel == referenceLabel })
            )
            let predictionText = normalizedCharacters(
                concatenatedPredictionText(
                    predictionSegments.filter { mapping[$0.predictedSpeakerLabel] == referenceLabel }
                )
            )
            referenceCharacterCount += referenceText.count
            editCount += levenshteinDistance(referenceText, predictionText)
        }

        // Text attributed to an unmatched predicted speaker is insertion-only error.
        let unmatchedPredictionText = predictionSegments.filter {
            mapping[$0.predictedSpeakerLabel] == nil
        }
        let unmatchedInsertionCount = normalizedCharacters(
            concatenatedPredictionText(unmatchedPredictionText)
        ).count
        editCount += unmatchedInsertionCount

        guard referenceCharacterCount > 0 else {
            return .unavailable(.emptyReferenceText)
        }
        return .measured(Double(editCount) / Double(referenceCharacterCount))
    }

    private static func concatenatedReferenceText(
        _ segments: [AudioBenchmarkReferenceSegment]
    ) -> String {
        segments.sorted(by: referenceSegmentOrder).map(\.textNormalized).joined()
    }

    private static func concatenatedPredictionText(_ segments: [PredictedSegment]) -> String {
        segments.sorted(by: predictionSegmentOrder).map(\.text).joined()
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        let nfc = text.precomposedStringWithCanonicalMapping
        let filteredScalars = nfc.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
        }
        return Array(String(String.UnicodeScalarView(filteredScalars)).precomposedStringWithCanonicalMapping)
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    // MARK: Helpers

    private static func checkedAdd(_ lhs: Double, _ rhs: Double) throws -> Double {
        let result = lhs + rhs
        guard result.isFinite else {
            throw AudioBenchmarkScoringError(code: .arithmeticOverflow)
        }
        return result
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs == rhs { return true }
        // Allow only floating-point summation noise, not a domain-sized epsilon that could turn a
        // genuinely better overlap measured in sub-milliseconds into a tie.
        let tolerance = max(lhs.ulp, rhs.ulp) * 256
        return abs(lhs - rhs) <= tolerance
    }

    private static func referenceSegmentOrder(
        _ lhs: AudioBenchmarkReferenceSegment,
        _ rhs: AudioBenchmarkReferenceSegment
    ) -> Bool {
        if lhs.startTimeSeconds != rhs.startTimeSeconds {
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        if lhs.endTimeSeconds != rhs.endTimeSeconds {
            return lhs.endTimeSeconds < rhs.endTimeSeconds
        }
        return lhs.speakerLabel < rhs.speakerLabel
    }

    private static func predictionSegmentOrder(_ lhs: PredictedSegment, _ rhs: PredictedSegment) -> Bool {
        if lhs.startTimeSeconds != rhs.startTimeSeconds {
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        if lhs.endTimeSeconds != rhs.endTimeSeconds {
            return lhs.endTimeSeconds < rhs.endTimeSeconds
        }
        return lhs.predictedSpeakerLabel < rhs.predictedSpeakerLabel
    }
}
