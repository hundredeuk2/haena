import AVFoundation
import Foundation
import XCTest
@testable import HAENA

final class AudioBenchmarkRunnerTests: XCTestCase {
    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testFakeProviderRunsSyntheticDevelopmentSequenceAndAggregatesMetrics() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02", "ARV0-T03"])
        defer { fixture.remove() }
        let provider = fakeProvider(responseCount: 3)

        let report = try await runner(provider: provider, fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(report.targetCount, 3)
        XCTAssertEqual(report.completedCount, 3)
        XCTAssertEqual(report.successCount, 3)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.cer.sampleCount, 3)
        XCTAssertEqual(report.cer.mean, 0)
        XCTAssertEqual(report.realTimeFactor.mean, 0)
        let invocationCount = await provider.invocationCount()
        XCTAssertEqual(invocationCount, 3)
        XCTAssertEqual(try contents(of: fixture.tempURL), [])
    }

    func testProviderFailureIsRecordedAndLaterCasesContinue() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02", "ARV0-T03"])
        defer { fixture.remove() }
        let provider = DeterministicAudioBenchmarkFakeProvider(
            responses: [
                .prediction(Self.prediction()),
                .failure(.timeout),
                .prediction(Self.prediction()),
            ]
        )

        let aggregate = try await runner(provider: provider, fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(aggregate.successCount, 2)
        XCTAssertEqual(aggregate.failureCount, 1)
        XCTAssertEqual(aggregate.timeoutCount, 1)
        let invocationCount = await provider.invocationCount()
        XCTAssertEqual(invocationCount, 3)
        let failed = try caseReport("ARV0-T02", fixture: fixture)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failureCategory, .providerTimeout)
        XCTAssertEqual(failed.diagnosticCode, .providerTimeout)
        XCTAssertEqual(try contents(of: fixture.tempURL), [], "failure must not retain the clip")
    }

    func testResumeSkipsAtomicCaseArtifactOnlyForIdenticalConfiguration() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02"])
        defer { fixture.remove() }
        let firstProvider = fakeProvider(responseCount: 1)

        let partial = try await runner(provider: firstProvider, fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL,
            control: AudioBenchmarkRunControl(maximumNewCases: 1)
        )
        XCTAssertEqual(partial.completedCount, 1)
        XCTAssertFalse(partial.isComplete)

        let resumedProvider = fakeProvider(responseCount: 1)
        let resumed = try await runner(provider: resumedProvider, fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(resumed.completedCount, 2)
        XCTAssertEqual(resumed.resumedCount, 1)
        XCTAssertTrue(resumed.isComplete)
        let resumedInvocationCount = await resumedProvider.invocationCount()
        XCTAssertEqual(resumedInvocationCount, 1)

        let mismatched = AudioBenchmarkRunConfiguration(
            metricSchemaVersion: AudioBenchmarkScore.metricSchemaVersion,
            providerID: "offline-fake",
            modelID: "different-model",
            caseIDs: fixture.cases.map(\.caseID)
        )
        let differentProvider = DeterministicAudioBenchmarkFakeProvider(
            modelID: "different-model",
            responses: []
        )
        do {
            _ = try await runner(provider: differentProvider, fixture: fixture).run(
                cases: fixture.cases,
                configuration: mismatched,
                outputDirectoryURL: fixture.outputURL
            )
            XCTFail("different configuration must not reuse existing reports")
        } catch let error as AudioBenchmarkRunError {
            XCTAssertEqual(error, .resumeConfigurationMismatch)
        }
    }

    func testAtomicWritesLeaveOnlyCompleteDecodableArtifacts() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }

        _ = try await runner(provider: fakeProvider(responseCount: 1), fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        let names = try contents(of: fixture.outputURL)
        XCTAssertEqual(
            names,
            ["ARV0-T01.report.json", "aggregate-report.json", "run-configuration.json"]
        )
        XCTAssertFalse(names.contains { $0.contains("tmp") || $0.hasPrefix(".") })
        _ = try AudioBenchmarkRunConfiguration.decoder.decode(
            AudioBenchmarkRunConfiguration.self,
            from: Data(contentsOf: fixture.outputURL.appendingPathComponent("run-configuration.json"))
        )
        _ = try AudioBenchmarkArtifactStore.decoder.decode(
            AudioBenchmarkAggregateReport.self,
            from: Data(contentsOf: fixture.outputURL.appendingPathComponent("aggregate-report.json"))
        )
        _ = try caseReport("ARV0-T01", fixture: fixture)
    }

    func testReportsExcludePathsTranscriptAndCredentialShapedData() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"], referenceText: "사용자 기밀 발화")
        defer { fixture.remove() }
        let sensitivePrediction = PredictedTranscript(
            providerID: "offline-fake",
            modelID: "deterministic-v0",
            processingDurationSeconds: 42,
            audioDurationSeconds: 1,
            segments: [
                PredictedSegment(
                    startTimeSeconds: 0,
                    endTimeSeconds: 1,
                    predictedSpeakerLabel: "speaker-secret",
                    text: "사용자 기밀 발화"
                ),
            ]
        )
        let provider = DeterministicAudioBenchmarkFakeProvider(
            responses: [.prediction(sensitivePrediction)]
        )

        _ = try await runner(provider: provider, fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        let combined = try contents(of: fixture.outputURL).reduce(into: Data()) { data, name in
            data.append(try Data(contentsOf: fixture.outputURL.appendingPathComponent(name)))
        }
        let text = String(decoding: combined, as: UTF8.self)
        for forbidden in [
            fixture.rootURL.path,
            fixture.sourceWAVURL.path,
            "사용자 기밀 발화",
            "speaker-secret",
            "api_key",
            "authorization",
            "request_header",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "leaked \(forbidden)")
        }
    }

    func testDeterministicInputsProduceByteIdenticalReportStructure() async throws {
        let first = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02"])
        let second = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02"])
        defer { first.remove(); second.remove() }

        _ = try await runner(provider: fakeProvider(responseCount: 2), fixture: first).run(
            cases: first.cases,
            configuration: first.configuration,
            outputDirectoryURL: first.outputURL
        )
        _ = try await runner(provider: fakeProvider(responseCount: 2), fixture: second).run(
            cases: second.cases,
            configuration: second.configuration,
            outputDirectoryURL: second.outputURL
        )

        for name in try contents(of: first.outputURL) {
            XCTAssertEqual(
                try Data(contentsOf: first.outputURL.appendingPathComponent(name)),
                try Data(contentsOf: second.outputURL.appendingPathComponent(name)),
                name
            )
        }
    }

    func testSealedCaseIsRejectedBeforeOutputOrTemporaryDirectoryExists() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-H01"], split: .sealedHoldout)
        defer { fixture.remove() }

        do {
            _ = try await runner(provider: fakeProvider(responseCount: 1), fixture: fixture).run(
                cases: fixture.cases,
                configuration: fixture.configuration,
                outputDirectoryURL: fixture.outputURL
            )
            XCTFail("sealed holdout must be refused")
        } catch let error as AudioBenchmarkRunError {
            XCTAssertEqual(error, .sealedHoldoutDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tempURL.path))
    }

    func testInvalidFrameRangeIsCaseFailureAndDoesNotInvokeProvider() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }
        let invalid = AudioBenchmarkRunCase(
            caseID: fixture.cases[0].caseID,
            split: .development,
            sourceClip: AudioBenchmarkSourceClip(
                sourceWAVURL: fixture.sourceWAVURL,
                startFrame: 7_999,
                frameCount: 2,
                expectedFormat: fixture.expectedFormat
            ),
            reference: fixture.cases[0].reference
        )
        let provider = fakeProvider(responseCount: 1)

        let aggregate = try await runner(provider: provider, fixture: fixture).run(
            cases: [invalid],
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(aggregate.failureCount, 1)
        let invocationCount = await provider.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(try caseReport("ARV0-T01", fixture: fixture).diagnosticCode, .frameRange)
        XCTAssertEqual(try contents(of: fixture.tempURL), [])
    }

    func testSampleFormatMismatchFailsBeforeProviderInvocation() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }
        let mismatched = AudioBenchmarkRunCase(
            caseID: fixture.cases[0].caseID,
            split: .development,
            sourceClip: AudioBenchmarkSourceClip(
                sourceWAVURL: fixture.sourceWAVURL,
                startFrame: 0,
                frameCount: 8_000,
                expectedFormat: AudioBenchmarkWAVFormat(
                    sampleRate: 16_000,
                    channelCount: 1,
                    bitDepth: 32,
                    sampleEncoding: .floatingPoint
                )
            ),
            reference: fixture.cases[0].reference
        )
        let provider = fakeProvider(responseCount: 1)

        _ = try await runner(provider: provider, fixture: fixture).run(
            cases: [mismatched],
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        let invocationCount = await provider.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(try caseReport("ARV0-T01", fixture: fixture).diagnosticCode, .sampleFormat)
    }

    func testStaleTemporaryCleanupIsAgeScopedAndBounded() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.tempURL, withIntermediateDirectories: true)
        let staleDate = Self.fixedDate.addingTimeInterval(-(2 * 24 * 60 * 60))
        for index in 0..<34 {
            let url = fixture.tempURL.appendingPathComponent("run-stale-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: url.path
            )
        }
        let freshURL = fixture.tempURL.appendingPathComponent("run-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.fixedDate],
            ofItemAtPath: freshURL.path
        )

        _ = try await runner(provider: fakeProvider(responseCount: 1), fixture: fixture).run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        let remaining = try contents(of: fixture.tempURL)
        XCTAssertEqual(remaining.count, 3, "only 32 stale directories may be deleted per invocation")
        XCTAssertTrue(remaining.contains("run-fresh"), "fresh temp directories are never scavenged")
    }

    func testRunnerMeasuresProviderWallClockForRTF() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }
        let monotonic = LockedSequence([10, 10.5])
        let provider = fakeProvider(responseCount: 1)
        let measuredRunner = AudioBenchmarkRunner(
            provider: provider,
            clipExtractor: fixture.extractor,
            now: { Self.fixedDate },
            monotonicSeconds: { monotonic.next() }
        )

        _ = try await measuredRunner.run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(try caseReport("ARV0-T01", fixture: fixture).realTimeFactor?.value, 0.5)
    }

    func testAggregateOfLargestFiniteMetricsRemainsFiniteAndEncodable() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01", "ARV0-T02"])
        defer { fixture.remove() }
        let provider = fakeProvider(responseCount: 2)
        let extremeRunner = AudioBenchmarkRunner(
            provider: provider,
            scorer: ExtremeScoring(),
            clipExtractor: fixture.extractor,
            now: { Self.fixedDate },
            monotonicSeconds: { 100 }
        )

        let aggregate = try await extremeRunner.run(
            cases: fixture.cases,
            configuration: fixture.configuration,
            outputDirectoryURL: fixture.outputURL
        )

        XCTAssertEqual(aggregate.cer.sampleCount, 2)
        XCTAssertEqual(aggregate.cer.mean, Double.greatestFiniteMagnitude)
        XCTAssertEqual(aggregate.cer.median, Double.greatestFiniteMagnitude)
        XCTAssertTrue(aggregate.cer.mean?.isFinite == true)
        XCTAssertNoThrow(try AudioBenchmarkArtifactStore.encoder.encode(aggregate))
    }

    func testAppAdapterRejectsMissingTimingWithoutPersistingProviderResponse() async throws {
        let fixture = try Fixture(caseIDs: ["ARV0-T01"])
        defer { fixture.remove() }
        let appProvider = AppProviderStub(
            result: TranscriptionResult(
                segments: [
                    TranscriptionSegment(
                        text: "발화",
                        startTime: nil,
                        endTime: 1,
                        speakerLabel: "speaker_0"
                    ),
                ],
                metadata: ModelRunMetadata(
                    provider: .openAI,
                    modelID: "gpt-4o-transcribe-diarize",
                    completedAt: Self.fixedDate
                )
            )
        )
        let adapter = AppTranscriptionAudioBenchmarkProvider(
            providerID: "openai",
            modelID: "gpt-4o-transcribe-diarize",
            provider: appProvider
        )

        do {
            _ = try await adapter.transcribe(
                audioFileURL: fixture.sourceWAVURL,
                expectedAudioDurationSeconds: 1
            )
            XCTFail("missing timestamp cannot be a normal prediction")
        } catch let error as AudioBenchmarkProviderError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    // MARK: Helpers

    private func runner(
        provider: some AudioBenchmarkProvider,
        fixture: Fixture
    ) -> AudioBenchmarkRunner {
        AudioBenchmarkRunner(
            provider: provider,
            clipExtractor: fixture.extractor,
            now: { Self.fixedDate },
            monotonicSeconds: { 100 }
        )
    }

    private func fakeProvider(responseCount: Int) -> DeterministicAudioBenchmarkFakeProvider {
        DeterministicAudioBenchmarkFakeProvider(
            responses: Array(repeating: .prediction(Self.prediction()), count: responseCount)
        )
    }

    private static func prediction() -> PredictedTranscript {
        PredictedTranscript(
            providerID: "offline-fake",
            modelID: "deterministic-v0",
            processingDurationSeconds: 0,
            audioDurationSeconds: 1,
            segments: [
                PredictedSegment(
                    startTimeSeconds: 0,
                    endTimeSeconds: 1,
                    predictedSpeakerLabel: "speaker_0",
                    text: "가"
                ),
            ]
        )
    }

    private func caseReport(_ caseID: String, fixture: Fixture) throws -> AudioBenchmarkCaseReport {
        try AudioBenchmarkArtifactStore.decoder.decode(
            AudioBenchmarkCaseReport.self,
            from: Data(
                contentsOf: fixture.outputURL.appendingPathComponent(caseID + ".report.json")
            )
        )
    }

    private func contents(of url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

private extension AudioBenchmarkRunnerTests {
    final class Fixture: @unchecked Sendable {
        let rootURL: URL
        let sourceWAVURL: URL
        let tempURL: URL
        let outputURL: URL
        let expectedFormat: AudioBenchmarkWAVFormat
        let cases: [AudioBenchmarkRunCase]
        let configuration: AudioBenchmarkRunConfiguration
        let extractor: AudioBenchmarkWAVClipExtractor

        init(
            caseIDs: [String],
            split: BenchmarkSplit = .development,
            referenceText: String = "가"
        ) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("haena-audio-runner-tests-\(UUID().uuidString)", isDirectory: true)
            let sourceURL = root.appendingPathComponent("synthetic.wav")
            let temporaryURL = root.appendingPathComponent("anonymous-temp", isDirectory: true)
            rootURL = root
            sourceWAVURL = sourceURL
            tempURL = temporaryURL
            outputURL = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.writeSyntheticWAV(to: sourceURL)

            let format = AudioBenchmarkWAVFormat(
                sampleRate: 8_000,
                channelCount: 1,
                bitDepth: 32,
                sampleEncoding: .floatingPoint
            )
            expectedFormat = format

            let reference = AudioBenchmarkReferenceTranscript(
                audioDurationSeconds: 1,
                segments: [
                    AudioBenchmarkReferenceSegment(
                        startTimeSeconds: 0,
                        endTimeSeconds: 1,
                        speakerLabel: "A",
                        textNormalized: referenceText
                    ),
                ]
            )
            cases = caseIDs.map {
                AudioBenchmarkRunCase(
                    caseID: $0,
                    split: split,
                    sourceClip: AudioBenchmarkSourceClip(
                        sourceWAVURL: sourceURL,
                        startFrame: 0,
                        frameCount: 8_000,
                        expectedFormat: format
                    ),
                    reference: reference
                )
            }
            configuration = AudioBenchmarkRunConfiguration(
                metricSchemaVersion: AudioBenchmarkScore.metricSchemaVersion,
                providerID: "offline-fake",
                modelID: "deterministic-v0",
                caseIDs: caseIDs
            )
            extractor = AudioBenchmarkWAVClipExtractor(
                temporaryRootURL: temporaryURL,
                now: { AudioBenchmarkRunnerTests.fixedDate }
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        private static func writeSyntheticWAV(to url: URL) throws {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 8_000,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = 8_000
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<8_000 {
                    samples[index] = Float(sin(Double(index) * 0.01) * 0.05)
                }
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }

    final class LockedSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval]

        init(_ values: [TimeInterval]) {
            self.values = values
        }

        func next() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty ? 0 : values.removeFirst()
        }
    }

    struct AppProviderStub: TranscriptionProvider {
        let result: TranscriptionResult
        let capabilities = TranscriptionCapabilities(
            fileTranscription: true,
            segmentTimestamps: true,
            speakerDiarization: true,
            wordTimestamps: false,
            maximumFileBytes: nil
        )

        func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
            result
        }
    }

    struct ExtremeScoring: AudioBenchmarkScoring {
        func score(
            prediction: PredictedTranscript,
            reference: AudioBenchmarkReferenceTranscript
        ) throws -> AudioBenchmarkScore {
            let maximum = AudioBenchmarkMetricValue.measured(Double.greatestFiniteMagnitude)
            return AudioBenchmarkScore(
                speakerMapping: [:],
                cer: maximum,
                speakerCountError: 0,
                der: maximum,
                speakerAttributionAccuracy: maximum,
                targetSpeakerBF1: maximum,
                speakerAttributedCER: maximum,
                realTimeFactor: maximum
            )
        }
    }
}
