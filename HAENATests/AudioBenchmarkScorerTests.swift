import XCTest

final class AudioBenchmarkScorerTests: XCTestCase {
    func testPerfectTranscriptProducesPerfectMetrics() throws {
        let reference = makeReference(
            duration: 10,
            segments: [
                ref(0, 5, "A", "안녕,"),
                ref(5, 10, "B", "세계!")
            ]
        )
        let prediction = makePrediction(
            duration: 10,
            processing: 2,
            segments: [
                pred(0, 5, "Speaker 1", "안녕"),
                pred(5, 10, "Speaker 0", "세계")
            ]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(score.speakerMapping, ["Speaker 0": "B", "Speaker 1": "A"])
        XCTAssertEqual(score.speakerCountError, 0)
        assertMetric(score.cer, equals: 0)
        assertMetric(score.der, equals: 0)
        assertMetric(score.speakerAttributionAccuracy, equals: 1)
        assertMetric(score.targetSpeakerBF1, equals: 1)
        assertMetric(score.speakerAttributedCER, equals: 0)
        assertMetric(score.realTimeFactor, equals: 0.2)
    }

    func testSpeakerLabelPermutationIsMatchedByTimeNotName() throws {
        let reference = makeReference(
            duration: 6,
            segments: [ref(0, 3, "A", "하나"), ref(3, 6, "B", "둘")]
        )
        let prediction = makePrediction(
            duration: 6,
            segments: [pred(0, 3, "B", "하나"), pred(3, 6, "A", "둘")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(score.speakerMapping, ["A": "B", "B": "A"])
        assertMetric(score.der, equals: 0)
        assertMetric(score.speakerAttributionAccuracy, equals: 1)
        assertMetric(score.speakerAttributedCER, equals: 0)
    }

    func testExtraSpeakerIsSignedOverCountAndFalseAlarm() throws {
        let reference = makeReference(
            duration: 10,
            segments: [ref(0, 3, "A", "가"), ref(3, 6, "B", "나")]
        )
        let prediction = makePrediction(
            duration: 10,
            segments: [
                pred(0, 3, "X", "가"),
                pred(3, 6, "Y", "나"),
                pred(6, 8, "Z", "다")
            ]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(score.speakerCountError, 1)
        XCTAssertNil(score.speakerMapping["Z"])
        assertMetric(score.der, equals: 2.0 / 6.0)
        assertMetric(score.speakerAttributedCER, equals: 0.5)
    }

    func testMissingSpeakerIsSignedUnderCountAndMiss() throws {
        let reference = makeReference(
            duration: 10,
            segments: [ref(0, 5, "A", "가"), ref(5, 10, "B", "나")]
        )
        let prediction = makePrediction(
            duration: 10,
            segments: [pred(0, 5, "X", "가")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(score.speakerCountError, -1)
        assertMetric(score.der, equals: 0.5)
        assertMetric(score.speakerAttributionAccuracy, equals: 0.5)
        assertMetric(score.targetSpeakerBF1, equals: 0)
        assertMetric(score.speakerAttributedCER, equals: 0.5)
    }

    func testEmptyPredictionIsValidFailedRecognitionResult() throws {
        let reference = makeReference(
            duration: 10,
            segments: [ref(0, 5, "A", "가"), ref(5, 10, "B", "나")]
        )

        let score = try AudioBenchmarkScorer.score(
            prediction: makePrediction(duration: 10, segments: []),
            reference: reference
        )

        XCTAssertEqual(score.speakerCountError, -2)
        assertMetric(score.cer, equals: 1)
        assertMetric(score.der, equals: 1)
        assertMetric(score.speakerAttributionAccuracy, equals: 0)
        assertMetric(score.targetSpeakerBF1, equals: 0)
        assertMetric(score.speakerAttributedCER, equals: 1)
    }

    func testEmptyReferenceMakesDenominatorMetricsUnavailable() throws {
        let score = try AudioBenchmarkScorer.score(
            prediction: makePrediction(duration: 5, segments: []),
            reference: makeReference(duration: 5, segments: [])
        )

        assertUnavailable(score.cer, reason: .emptyReferenceText)
        assertUnavailable(score.der, reason: .noReferenceSpeech)
        assertUnavailable(score.speakerAttributionAccuracy, reason: .noReferenceSpeech)
        assertUnavailable(score.targetSpeakerBF1, reason: .targetSpeakerAbsent)
        assertUnavailable(score.speakerAttributedCER, reason: .emptyReferenceText)
        assertMetric(score.realTimeFactor, equals: 0.2)
    }

    func testPartialBoundaryOverlapContributesSpeakerConfusion() throws {
        let reference = makeReference(
            duration: 10,
            segments: [ref(0, 5, "A", "가"), ref(5, 10, "B", "나")]
        )
        let prediction = makePrediction(
            duration: 10,
            segments: [pred(0, 4, "X", "가"), pred(4, 10, "Y", "나")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(score.speakerMapping, ["X": "A", "Y": "B"])
        assertMetric(score.der, equals: 0.1)
        assertMetric(score.speakerAttributionAccuracy, equals: 0.9)
        assertMetric(score.targetSpeakerBF1, equals: 10.0 / 11.0)
    }

    func testEqualOverlapTieUsesLexicographicallySmallestAssignmentVector() throws {
        let reference = makeReference(
            duration: 4,
            segments: [ref(0, 2, "A", "가"), ref(2, 4, "B", "나")]
        )
        let prediction = makePrediction(
            duration: 4,
            segments: [
                pred(0, 1, "X", "가"),
                pred(1, 3, "Y", "중"),
                pred(3, 4, "X", "나")
            ]
        )

        let first = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)
        let second = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        XCTAssertEqual(first.speakerMapping, ["X": "A", "Y": "B"])
        XCTAssertEqual(first, second)
    }

    func testTargetSpeakerAbsentIsUnavailableRatherThanZero() throws {
        let reference = makeReference(
            duration: 3,
            segments: [ref(0, 3, "A", "가")]
        )
        let prediction = makePrediction(
            duration: 3,
            segments: [pred(0, 3, "X", "가")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        assertUnavailable(score.targetSpeakerBF1, reason: .targetSpeakerAbsent)
    }

    func testCERInsertionDeletionAndSubstitution() throws {
        let reference = makeReference(
            duration: 1,
            segments: [ref(0, 1, "A", "가나다")]
        )
        let predictions = ["가나다라", "가나", "가나마"]

        for text in predictions {
            let score = try AudioBenchmarkScorer.score(
                prediction: makePrediction(duration: 1, segments: [pred(0, 1, "X", text)]),
                reference: reference
            )
            assertMetric(score.cer, equals: 1.0 / 3.0)
        }
    }

    func testCERUsesKoreanNFCAndIgnoresUnicodeWhitespaceAndPunctuation() throws {
        let decomposedGa = "\u{1100}\u{1161}"
        let reference = makeReference(
            duration: 1,
            segments: [ref(0, 1, "A", "가, 나!")]
        )
        let prediction = makePrediction(
            duration: 1,
            segments: [pred(0, 1, "X", "\(decomposedGa)\u{3000}나")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        assertMetric(score.cer, equals: 0)
    }

    func testMissingTimestampCannotDecodeAsNormalPredictionSegment() {
        let json = Data(
            #"{"start_time_seconds":0,"predicted_speaker_label":"X","text":"가"}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(PredictedSegment.self, from: json))
    }

    func testInvalidSegmentTimesAreRejectedWithFiniteCodes() {
        let reference = makeReference(duration: 10, segments: [ref(0, 10, "B", "가")])
        let cases: [(PredictedSegment, AudioBenchmarkScoringDiagnosticCode)] = [
            (pred(-1, 1, "X", "가"), .segmentTimeNegative),
            (pred(2, 2, "X", "가"), .segmentEndNotAfterStart),
            (pred(3, 2, "X", "가"), .segmentEndNotAfterStart),
            (pred(0, 11, "X", "가"), .segmentOutsideClip),
            (pred(0, .infinity, "X", "가"), .segmentTimeNotFinite)
        ]

        for (segment, expectedCode) in cases {
            XCTAssertThrowsError(
                try AudioBenchmarkScorer.score(
                    prediction: makePrediction(duration: 10, segments: [segment]),
                    reference: reference
                )
            ) { error in
                XCTAssertEqual((error as? AudioBenchmarkScoringError)?.code, expectedCode)
            }
        }
    }

    func testZeroDurationAndDurationMismatchAreRejected() {
        XCTAssertThrowsError(
            try AudioBenchmarkScorer.score(
                prediction: makePrediction(duration: 0, segments: []),
                reference: makeReference(duration: 0, segments: [])
            )
        ) { error in
            XCTAssertEqual(
                (error as? AudioBenchmarkScoringError)?.code,
                .predictionAudioDurationInvalid
            )
        }

        XCTAssertThrowsError(
            try AudioBenchmarkScorer.score(
                prediction: makePrediction(duration: 9, segments: []),
                reference: makeReference(duration: 10, segments: [])
            )
        ) { error in
            XCTAssertEqual((error as? AudioBenchmarkScoringError)?.code, .audioDurationMismatch)
        }
    }

    func testEmptySpeakerAndTextAreRejected() {
        let reference = makeReference(duration: 1, segments: [ref(0, 1, "B", "가")])
        let invalid: [(PredictedSegment, AudioBenchmarkScoringDiagnosticCode)] = [
            (pred(0, 1, "  ", "가"), .segmentSpeakerLabelEmpty),
            (pred(0, 1, "X", "\n"), .segmentTextEmpty)
        ]

        for (segment, expectedCode) in invalid {
            XCTAssertThrowsError(
                try AudioBenchmarkScorer.score(
                    prediction: makePrediction(duration: 1, segments: [segment]),
                    reference: reference
                )
            ) { error in
                XCTAssertEqual((error as? AudioBenchmarkScoringError)?.code, expectedCode)
            }
        }
    }

    func testOverlappingPredictionAndReferenceAreRejected() {
        let validReference = makeReference(duration: 3, segments: [ref(0, 3, "B", "가")])
        XCTAssertThrowsError(
            try AudioBenchmarkScorer.score(
                prediction: makePrediction(
                    duration: 3,
                    segments: [pred(0, 2, "X", "가"), pred(1, 3, "Y", "나")]
                ),
                reference: validReference
            )
        ) { error in
            XCTAssertEqual(
                (error as? AudioBenchmarkScoringError)?.code,
                .overlappingPredictionSegments
            )
        }

        let overlappingReference = makeReference(
            duration: 3,
            segments: [ref(0, 2, "A", "가"), ref(1, 3, "B", "나")]
        )
        XCTAssertThrowsError(
            try AudioBenchmarkScorer.score(
                prediction: makePrediction(duration: 3, segments: []),
                reference: overlappingReference
            )
        ) { error in
            XCTAssertEqual(
                (error as? AudioBenchmarkScoringError)?.code,
                .overlappingReferenceSegments
            )
        }
    }

    func testVeryLargeFiniteDurationDoesNotOverflowF1OrMatching() throws {
        let duration = 1e300
        let reference = makeReference(
            duration: duration,
            segments: [ref(0, duration, "B", "가")]
        )
        let prediction = makePrediction(
            duration: duration,
            processing: duration,
            segments: [pred(0, duration, "X", "가")]
        )

        let score = try AudioBenchmarkScorer.score(prediction: prediction, reference: reference)

        assertMetric(score.der, equals: 0)
        assertMetric(score.targetSpeakerBF1, equals: 1)
        assertMetric(score.realTimeFactor, equals: 1)
    }

    func testOverflowingRTFIsRejectedInsteadOfEmittingInfinity() {
        let tinyDuration = Double.leastNonzeroMagnitude

        XCTAssertThrowsError(
            try AudioBenchmarkScorer.score(
                prediction: makePrediction(
                    duration: tinyDuration,
                    processing: Double.greatestFiniteMagnitude,
                    segments: []
                ),
                reference: makeReference(duration: tinyDuration, segments: [])
            )
        ) { error in
            XCTAssertEqual((error as? AudioBenchmarkScoringError)?.code, .arithmeticOverflow)
        }
    }

    func testMetricSchemaVersionIsFrozen() {
        XCTAssertEqual(AudioBenchmarkScore.metricSchemaVersion, "haena-audio-stt-metrics-v0.1")
    }

    // MARK: Fixtures

    private func makePrediction(
        duration: Double,
        processing: Double = 1,
        segments: [PredictedSegment]
    ) -> PredictedTranscript {
        PredictedTranscript(
            providerID: "fake-provider",
            modelID: "fake-model-v0",
            processingDurationSeconds: processing,
            audioDurationSeconds: duration,
            segments: segments
        )
    }

    private func makeReference(
        duration: Double,
        target: String = "B",
        segments: [AudioBenchmarkReferenceSegment]
    ) -> AudioBenchmarkReferenceTranscript {
        AudioBenchmarkReferenceTranscript(
            audioDurationSeconds: duration,
            targetSpeakerLabel: target,
            segments: segments
        )
    }

    private func pred(
        _ start: Double,
        _ end: Double,
        _ speaker: String,
        _ text: String
    ) -> PredictedSegment {
        PredictedSegment(
            startTimeSeconds: start,
            endTimeSeconds: end,
            predictedSpeakerLabel: speaker,
            text: text
        )
    }

    private func ref(
        _ start: Double,
        _ end: Double,
        _ speaker: String,
        _ text: String
    ) -> AudioBenchmarkReferenceSegment {
        AudioBenchmarkReferenceSegment(
            startTimeSeconds: start,
            endTimeSeconds: end,
            speakerLabel: speaker,
            textNormalized: text
        )
    }

    private func assertMetric(
        _ metric: AudioBenchmarkMetricValue,
        equals expected: Double,
        accuracy: Double = 1e-12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(metric.unavailableReason, file: file, line: line)
        XCTAssertNotNil(metric.value, file: file, line: line)
        if let value = metric.value {
            XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
        }
    }

    private func assertUnavailable(
        _ metric: AudioBenchmarkMetricValue,
        reason: AudioBenchmarkMetricUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(metric.value, file: file, line: line)
        XCTAssertEqual(metric.unavailableReason, reason, file: file, line: line)
    }
}
