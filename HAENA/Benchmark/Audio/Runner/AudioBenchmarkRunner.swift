import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

protocol AudioBenchmarkScoring: Sendable {
    func score(
        prediction: PredictedTranscript,
        reference: AudioBenchmarkReferenceTranscript
    ) throws -> AudioBenchmarkScore
}

struct AudioBenchmarkV0Scoring: AudioBenchmarkScoring {
    func score(
        prediction: PredictedTranscript,
        reference: AudioBenchmarkReferenceTranscript
    ) throws -> AudioBenchmarkScore {
        try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)
    }
}

struct AudioBenchmarkRunControl: Equatable, Sendable {
    /// Testable interruption seam. It is deliberately excluded from the configuration hash: a
    /// resumed invocation must identify the same full run even when the first process stopped after
    /// writing only a subset of cases.
    let maximumNewCases: Int?

    static let uninterrupted = AudioBenchmarkRunControl(maximumNewCases: nil)
}

/// Sequential audio benchmark orchestrator.
///
/// Discovery and split authorization happen before constructing `AudioBenchmarkRunCase`. This type
/// still refuses any sealed case before creating the output directory, providing a second boundary
/// at the last component capable of invoking a provider.
struct AudioBenchmarkRunner: Sendable {
    let provider: any AudioBenchmarkProvider
    let scorer: any AudioBenchmarkScoring
    let clipExtractor: AudioBenchmarkWAVClipExtractor
    let now: @Sendable () -> Date
    let monotonicSeconds: @Sendable () -> TimeInterval

    init(
        provider: any AudioBenchmarkProvider,
        scorer: any AudioBenchmarkScoring = AudioBenchmarkV0Scoring(),
        clipExtractor: AudioBenchmarkWAVClipExtractor = AudioBenchmarkWAVClipExtractor(),
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicSeconds: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.provider = provider
        self.scorer = scorer
        self.clipExtractor = clipExtractor
        self.now = now
        self.monotonicSeconds = monotonicSeconds
    }

    func run(
        cases: [AudioBenchmarkRunCase],
        configuration: AudioBenchmarkRunConfiguration,
        outputDirectoryURL: URL,
        control: AudioBenchmarkRunControl = .uninterrupted
    ) async throws -> AudioBenchmarkAggregateReport {
        // This entire block precedes even construction of the artifact store. A sealed request has
        // no observable output path and cannot invoke temp-WAV extraction.
        guard !cases.isEmpty,
              cases.allSatisfy({ $0.split == .development }) else {
            throw AudioBenchmarkRunError.sealedHoldoutDenied
        }
        guard configuration.isValid,
              configuration.metricSchemaVersion == AudioBenchmarkScore.metricSchemaVersion,
              Set(configuration.caseIDs) == Set(cases.map(\.caseID)),
              Set(cases.map(\.caseID)).count == cases.count else {
            throw AudioBenchmarkRunError.invalidConfiguration
        }
        guard configuration.providerID == provider.providerID,
              configuration.modelID == provider.modelID else {
            throw AudioBenchmarkRunError.providerConfigurationMismatch
        }

        let orderedCases = cases.sorted { $0.caseID < $1.caseID }
        let store = AudioBenchmarkArtifactStore(outputDirectoryURL: outputDirectoryURL)
        try store.prepare(for: configuration)

        let previousAggregate = try store.existingAggregateReport(configuration: configuration)
        let startedAt = previousAggregate?.startedAt ?? now()
        var reports: [AudioBenchmarkCaseReport] = []
        var resumedCount = 0
        var casesRunThisInvocation = 0

        for runCase in orderedCases {
            if let existing = try store.existingCaseReport(
                caseID: runCase.caseID,
                configuration: configuration
            ) {
                reports.append(existing)
                resumedCount += 1
                continue
            }

            if let maximum = control.maximumNewCases,
               casesRunThisInvocation >= max(0, maximum) {
                continue
            }

            let report = await runOne(
                runCase,
                configuration: configuration,
                timestamp: now()
            )
            try store.write(report)
            reports.append(report)
            casesRunThisInvocation += 1

            // A valid aggregate always follows the latest atomic case file. If the process stops
            // after this point, resume can trust every completed case and skip it.
            let intermediate = Self.aggregate(
                reports: reports,
                configuration: configuration,
                targetCount: orderedCases.count,
                resumedCount: resumedCount,
                startedAt: startedAt,
                finishedAt: now()
            )
            try store.write(intermediate)
        }

        let final = Self.aggregate(
            reports: reports,
            configuration: configuration,
            targetCount: orderedCases.count,
            resumedCount: resumedCount,
            startedAt: startedAt,
            finishedAt: now()
        )
        try store.write(final)
        return final
    }

    private func runOne(
        _ runCase: AudioBenchmarkRunCase,
        configuration: AudioBenchmarkRunConfiguration,
        timestamp: Date
    ) async -> AudioBenchmarkCaseReport {
        do {
            let score = try await clipExtractor.withTemporaryClip(runCase.sourceClip) { clipURL, clipDuration in
                let providerStarted = monotonicSeconds()
                let suppliedPrediction = try await provider.transcribe(
                    audioFileURL: clipURL,
                    expectedAudioDurationSeconds: clipDuration
                )
                let providerFinished = monotonicSeconds()
                let processingDuration = providerFinished - providerStarted

                guard processingDuration.isFinite,
                      processingDuration >= 0,
                      suppliedPrediction.providerID == configuration.providerID,
                      suppliedPrediction.modelID == configuration.modelID,
                      suppliedPrediction.processingDurationSeconds.isFinite,
                      suppliedPrediction.processingDurationSeconds >= 0,
                      suppliedPrediction.audioDurationSeconds.isFinite,
                      abs(suppliedPrediction.audioDurationSeconds - clipDuration) <= 0.000_001 else {
                    throw AudioBenchmarkProviderError.invalidResponse
                }

                // The runner owns RTF provenance. Provider-supplied timing is validated but never
                // trusted or persisted; elapsed wall-clock time includes all provider/network wait.
                let normalized = PredictedTranscript(
                    providerID: configuration.providerID,
                    modelID: configuration.modelID,
                    processingDurationSeconds: processingDuration,
                    audioDurationSeconds: clipDuration,
                    segments: suppliedPrediction.segments
                )
                return try scorer.score(prediction: normalized, reference: runCase.reference)
            }

            return AudioBenchmarkCaseReport(
                caseID: runCase.caseID,
                split: runCase.split,
                providerID: configuration.providerID,
                modelID: configuration.modelID,
                metricSchemaVersion: configuration.metricSchemaVersion,
                configurationHash: configuration.canonicalHash,
                status: .succeeded,
                cer: score.cer,
                speakerCountError: score.speakerCountError,
                der: score.der,
                speakerAttributionAccuracy: score.speakerAttributionAccuracy,
                targetSpeakerBF1: score.targetSpeakerBF1,
                speakerAttributedCER: score.speakerAttributedCER,
                realTimeFactor: score.realTimeFactor,
                failureCategory: nil,
                diagnosticCode: nil,
                timestamp: timestamp
            )
        } catch {
            let failure = Self.reportFailure(for: error)
            return AudioBenchmarkCaseReport(
                caseID: runCase.caseID,
                split: runCase.split,
                providerID: configuration.providerID,
                modelID: configuration.modelID,
                metricSchemaVersion: configuration.metricSchemaVersion,
                configurationHash: configuration.canonicalHash,
                status: .failed,
                cer: nil,
                speakerCountError: nil,
                der: nil,
                speakerAttributionAccuracy: nil,
                targetSpeakerBF1: nil,
                speakerAttributedCER: nil,
                realTimeFactor: nil,
                failureCategory: failure.category,
                diagnosticCode: failure.code,
                timestamp: timestamp
            )
        }
    }

    private static func reportFailure(
        for error: Error
    ) -> (category: AudioBenchmarkFailureCategory, code: AudioBenchmarkDiagnosticCode) {
        if let extraction = error as? AudioBenchmarkClipExtractionError {
            switch extraction {
            case .invalidSourceType:
                return (.sourceFormatInvalid, .sourceType)
            case .sourceMissing:
                return (.sourceMissing, .sourceMissing)
            case .sourceUnreadable:
                return (.sourceMissing, .sourceUnreadable)
            case .invalidAudioFormat:
                return (.sourceFormatInvalid, .audioFormat)
            case .sampleFormatMismatch:
                return (.sourceFormatInvalid, .sampleFormat)
            case .invalidFrameRange:
                return (.sourceFormatInvalid, .frameRange)
            case .temporaryDirectoryUnavailable:
                return (.clipExtractionFailed, .temporaryDirectory)
            case .clipWriteFailed:
                return (.clipExtractionFailed, .clipWrite)
            case .temporaryCleanupFailed:
                return (.clipExtractionFailed, .temporaryCleanup)
            }
        }
        if let provider = error as? AudioBenchmarkProviderError {
            switch provider {
            case .missingCredential:
                return (.providerFailed, .providerCredential)
            case .unauthorized:
                return (.providerFailed, .providerUnauthorized)
            case .rateLimited:
                return (.providerFailed, .providerRateLimited)
            case .timeout:
                return (.providerTimeout, .providerTimeout)
            case .networkUnavailable:
                return (.providerFailed, .providerNetwork)
            case .rejected:
                return (.providerFailed, .providerRejected)
            case .unavailable:
                return (.providerFailed, .providerUnavailable)
            case .invalidResponse:
                return (.predictionInvalid, .providerResponse)
            }
        }
        if let scoring = error as? AudioBenchmarkScoringError {
            switch scoring.code {
            case .predictionAudioDurationInvalid,
                 .processingDurationInvalid,
                 .providerIdentifierEmpty,
                 .modelIdentifierEmpty,
                 .overlappingPredictionSegments:
                return (.predictionInvalid, .predictionContract)
            case .referenceAudioDurationInvalid,
                 .targetSpeakerLabelEmpty,
                 .overlappingReferenceSegments:
                return (.referenceInvalid, .referenceContract)
            case .audioDurationMismatch,
                 .segmentTimeNotFinite,
                 .segmentTimeNegative,
                 .segmentEndNotAfterStart,
                 .segmentOutsideClip,
                 .segmentSpeakerLabelEmpty,
                 .segmentTextEmpty,
                 .arithmeticOverflow:
                return (.scoringFailed, .scoringContract)
            }
        }
        return (.scoringFailed, .scoringContract)
    }

    // MARK: Aggregate statistics

    private static func aggregate(
        reports: [AudioBenchmarkCaseReport],
        configuration: AudioBenchmarkRunConfiguration,
        targetCount: Int,
        resumedCount: Int,
        startedAt: Date,
        finishedAt: Date
    ) -> AudioBenchmarkAggregateReport {
        let ordered = reports.sorted { $0.caseID < $1.caseID }
        let succeeded = ordered.filter { $0.status == .succeeded }

        return AudioBenchmarkAggregateReport(
            benchmark: configuration.benchmark,
            configurationHash: configuration.canonicalHash,
            targetCount: targetCount,
            completedCount: ordered.count,
            successCount: succeeded.count,
            failureCount: ordered.count - succeeded.count,
            timeoutCount: ordered.filter { $0.failureCategory == .providerTimeout }.count,
            resumedCount: resumedCount,
            isComplete: ordered.count == targetCount,
            cer: summary(succeeded.compactMap { $0.cer?.value }, includeP95: true),
            speakerCountError: summary(succeeded.compactMap { $0.speakerCountError.map(Double.init) }, includeP95: false),
            der: summary(succeeded.compactMap { $0.der?.value }, includeP95: true),
            speakerAttributionAccuracy: summary(
                succeeded.compactMap { $0.speakerAttributionAccuracy?.value },
                includeP95: false
            ),
            targetSpeakerBF1: summary(succeeded.compactMap { $0.targetSpeakerBF1?.value }, includeP95: false),
            speakerAttributedCER: summary(
                succeeded.compactMap { $0.speakerAttributedCER?.value },
                includeP95: true
            ),
            realTimeFactor: summary(succeeded.compactMap { $0.realTimeFactor?.value }, includeP95: true),
            unavailableMetrics: unavailableMetricCounts(in: succeeded),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private static func summary(_ values: [Double], includeP95: Bool) -> AudioBenchmarkMetricSummary {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else {
            return AudioBenchmarkMetricSummary(sampleCount: 0, mean: nil, median: nil, p95: nil)
        }
        let scale = finite.reduce(0) { max($0, abs($1)) }
        let mean: Double
        if scale == 0 {
            mean = 0
        } else {
            let scaledSum = finite.reduce(0) { $0 + ($1 / scale) }
            mean = (scaledSum / Double(finite.count)) * scale
        }
        let median: Double
        if finite.count.isMultiple(of: 2) {
            median = finite[finite.count / 2 - 1] / 2 + finite[finite.count / 2] / 2
        } else {
            median = finite[finite.count / 2]
        }
        let p95: Double?
        if includeP95 {
            let index = max(0, Int(ceil(Double(finite.count) * 0.95)) - 1)
            p95 = finite[index]
        } else {
            p95 = nil
        }
        return AudioBenchmarkMetricSummary(
            sampleCount: finite.count,
            mean: mean,
            median: median,
            p95: p95
        )
    }

    private static func unavailableMetricCounts(
        in reports: [AudioBenchmarkCaseReport]
    ) -> [AudioBenchmarkMetricAvailability] {
        let metrics: [(String, (AudioBenchmarkCaseReport) -> AudioBenchmarkMetricValue?)] = [
            ("cer", { $0.cer }),
            ("der", { $0.der }),
            ("speaker_attribution_accuracy", { $0.speakerAttributionAccuracy }),
            ("target_speaker_b_f1", { $0.targetSpeakerBF1 }),
            ("speaker_attributed_cer", { $0.speakerAttributedCER }),
            ("real_time_factor", { $0.realTimeFactor }),
        ]

        return metrics.map { name, value in
            let counts = Dictionary(grouping: reports.compactMap { value($0)?.unavailableReason }, by: { $0 })
            let reasons = counts.map {
                AudioBenchmarkUnavailableReasonCount(reason: $0.key, count: $0.value.count)
            }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
            return AudioBenchmarkMetricAvailability(metric: name, unavailable: reasons)
        }
    }
}
