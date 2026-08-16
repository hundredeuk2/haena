import AVFoundation
import Foundation
import XCTest
@testable import HAENA

final class AudioBenchmarkSyntheticEndToEndTests: XCTestCase {
    func testRealDevelopmentRunTouchesOnlyAuthorizedGoldAndSourceWAVs() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let datasetRoot = repositoryRoot.appendingPathComponent(
            "data/benchmarks/haena-v0/audio-robustness-v0",
            isDirectory: true
        )
        let sourceRoot = repositoryRoot.appendingPathComponent(
            "data/benchmarks/002.주요 영역별 회의 음성인식 데이터/01.데이터",
            isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: datasetRoot.appendingPathComponent("source-index.jsonl").path
        ), FileManager.default.fileExists(atPath: sourceRoot.path) else {
            throw XCTSkip("Local benchmark corpus is unavailable.")
        }

        let recorder = SyntheticRecordingFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: datasetRoot,
            sourceAssetRoot: sourceRoot,
            fileManager: recorder
        )
        let entries = try store.authorizedEntries(for: .development)
        XCTAssertEqual(entries.count, 16)
        let runCases = try entries.map { entry in
            let payload = try JSONDecoder().decode(
                AuthorizedAudioCase.self,
                from: try store.caseData(for: entry)
            )
            return try payload.runCase(entry: entry, store: store)
        }

        let responses = runCases.map { runCase in
            DeterministicAudioBenchmarkFakeProvider.Response.prediction(
                PredictedTranscript(
                    providerID: "offline-fake",
                    modelID: "real-corpus-pipeline-v0",
                    processingDurationSeconds: 0,
                    audioDurationSeconds: runCase.reference.audioDurationSeconds,
                    segments: []
                )
            )
        }
        let provider = DeterministicAudioBenchmarkFakeProvider(
            modelID: "real-corpus-pipeline-v0",
            responses: responses
        )
        let configuration = AudioBenchmarkRunConfiguration(
            metricSchemaVersion: AudioBenchmarkScore.metricSchemaVersion,
            providerID: provider.providerID,
            modelID: provider.modelID,
            caseIDs: runCases.map(\.caseID)
        )
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("haena-real-audio-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let runner = AudioBenchmarkRunner(
            provider: provider,
            clipExtractor: AudioBenchmarkWAVClipExtractor(
                temporaryRootURL: testRoot.appendingPathComponent("clips", isDirectory: true),
                fileManager: recorder
            )
        )
        let aggregate = try await runner.run(
            cases: runCases,
            configuration: configuration,
            outputDirectoryURL: testRoot.appendingPathComponent("reports", isDirectory: true)
        )

        XCTAssertEqual(aggregate.targetCount, 16)
        XCTAssertEqual(aggregate.successCount, 16)
        XCTAssertEqual(aggregate.failureCount, 0)
        XCTAssertTrue(aggregate.isComplete)

        let accesses = recorder.accessedPaths
        let expectedGoldPaths = Set(entries.map {
            datasetRoot.appendingPathComponent("gold/\($0.caseID).json").standardizedFileURL.path
        })
        let accessedGoldPaths = Set(accesses.filter {
            $0.hasPrefix(datasetRoot.appendingPathComponent("gold", isDirectory: true).path + "/")
        })
        XCTAssertEqual(accessedGoldPaths, expectedGoldPaths)
        XCTAssertFalse(accesses.contains { $0.hasSuffix("manifest.jsonl") })

        let expectedSourceWAVPaths = Set(runCases.map { $0.sourceClip.sourceWAVURL.standardizedFileURL.path })
        let accessedSourceWAVPaths = Set(accesses.filter {
            $0.hasPrefix(sourceRoot.path + "/") && $0.lowercased().hasSuffix(".wav")
        })
        XCTAssertFalse(accessedSourceWAVPaths.isEmpty)
        XCTAssertTrue(accessedSourceWAVPaths.isSubset(of: expectedSourceWAVPaths))
    }

    func testAuthorizedIndexSplitOverridesStaleGoldSplit() throws {
        let fixture = try SyntheticAudioFixture()
        defer { fixture.remove() }
        let goldURL = fixture.datasetRoot.appendingPathComponent("gold/ARV0-E01.json")
        let staleGold = """
        {
          "schema_version":"haena-benchmark-v0.1",
          "benchmark":"audio-robustness-v0",
          "case_id":"ARV0-E01",
          "split":"sealed_holdout",
          "review_status":"source_aligned_label",
          "target_speaker":"B",
          "source":{"audio_path":"wav/development.wav"},
          "clip":{"duration_seconds":1,"start_frame":0,"end_frame":8000},
          "audio_format":{"channels":1,"sample_rate_hz":8000,"sample_width_bytes":4,"frame_count":8000,"compression":"NONE"},
          "gold":{"status":"source_aligned_label","transcript":[{"start_seconds":0,"end_seconds":1,"speaker":"B","text_normalized":"가"}],"metric_scope":["cer","speaker_count_error","der","speaker_attribution_accuracy","target_speaker_b_f1","speaker_attributed_cer","real_time_factor"]}
        }
        """
        try Data(staleGold.utf8).write(to: goldURL)
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot
        )
        let entry = try XCTUnwrap(try store.authorizedEntries(for: .development).first)
        let payload = try JSONDecoder().decode(
            AuthorizedAudioCase.self,
            from: try store.caseData(for: entry)
        )

        XCTAssertEqual(try payload.runCase(entry: entry, store: store).split, .development)
    }

    func testAuthorizedGoldRejectsMissingAdditionalAndDuplicateMetricScope() throws {
        let invalidScopes = [
            ["cer", "speaker_count_error", "speaker_attribution_accuracy", "target_speaker_b_f1", "speaker_attributed_cer", "real_time_factor"],
            ["cer", "speaker_count_error", "der", "speaker_attribution_accuracy", "target_speaker_b_f1", "speaker_attributed_cer", "real_time_factor", "unexpected"],
            ["cer", "speaker_count_error", "der", "speaker_attribution_accuracy", "target_speaker_b_f1", "speaker_attributed_cer", "real_time_factor", "der"],
        ]

        for scope in invalidScopes {
            let fixture = try SyntheticAudioFixture()
            defer { fixture.remove() }
            let store = AudioBenchmarkCaseStore(
                datasetRoot: fixture.datasetRoot,
                sourceAssetRoot: fixture.sourceRoot
            )
            let entry = try XCTUnwrap(try store.authorizedEntries(for: .development).first)
            let scopeData = try JSONSerialization.data(withJSONObject: scope)
            let scopeJSON = String(decoding: scopeData, as: UTF8.self)
            let gold = """
            {
              "schema_version":"haena-benchmark-v0.1",
              "benchmark":"audio-robustness-v0",
              "case_id":"ARV0-E01",
              "split":"development",
              "review_status":"source_aligned_label",
              "target_speaker":"B",
              "source":{"audio_path":"wav/development.wav"},
              "clip":{"duration_seconds":1,"start_frame":0,"end_frame":8000},
              "audio_format":{"channels":1,"sample_rate_hz":8000,"sample_width_bytes":4,"frame_count":8000,"compression":"NONE"},
              "gold":{"status":"source_aligned_label","transcript":[{"start_seconds":0,"end_seconds":1,"speaker":"B","text_normalized":"가"}],"metric_scope":\(scopeJSON)}
            }
            """
            try Data(gold.utf8).write(
                to: fixture.datasetRoot.appendingPathComponent("gold/ARV0-E01.json")
            )

            XCTAssertThrowsError(
                try JSONDecoder().decode(AuthorizedAudioCase.self, from: try store.caseData(for: entry))
            )
        }
    }

    func testMetadataDiscoveryThroughFakeProviderProducesTranscriptFreeReport() async throws {
        let fixture = try SyntheticAudioFixture()
        defer { fixture.remove() }
        let recorder = SyntheticRecordingFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )

        let entries = try store.authorizedEntries(for: .development)
        XCTAssertEqual(entries.map(\.caseID), ["ARV0-E01"])
        let entry = try XCTUnwrap(entries.first)
        let payload = try JSONDecoder().decode(
            SyntheticAuthorizedCase.self,
            from: store.caseData(for: entry)
        )
        let sourceURL = try store.authorizedSourceAssetURL(
            relativePath: payload.sourceAudioPath,
            for: entry
        )
        let reference = AudioBenchmarkReferenceTranscript(
            audioDurationSeconds: payload.durationSeconds,
            segments: payload.reference.map {
                AudioBenchmarkReferenceSegment(
                    startTimeSeconds: $0.startSeconds,
                    endTimeSeconds: $0.endSeconds,
                    speakerLabel: $0.speaker,
                    textNormalized: $0.textNormalized
                )
            }
        )
        let runCase = AudioBenchmarkRunCase(
            caseID: entry.caseID,
            split: .development,
            sourceClip: AudioBenchmarkSourceClip(
                sourceWAVURL: sourceURL,
                startFrame: AVAudioFramePosition(payload.startFrame),
                frameCount: AVAudioFrameCount(payload.frameCount),
                expectedFormat: AudioBenchmarkWAVFormat(
                    sampleRate: 8_000,
                    channelCount: 1,
                    bitDepth: 32,
                    sampleEncoding: .floatingPoint
                )
            ),
            reference: reference
        )
        let provider = DeterministicAudioBenchmarkFakeProvider(modelID: "synthetic-v0", responses: [
            .prediction(PredictedTranscript(
                providerID: "offline-fake",
                modelID: "synthetic-v0",
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
            )),
        ])
        let configuration = AudioBenchmarkRunConfiguration(
            metricSchemaVersion: AudioBenchmarkScore.metricSchemaVersion,
            providerID: "offline-fake",
            modelID: "synthetic-v0",
            caseIDs: [entry.caseID]
        )
        let runner = AudioBenchmarkRunner(
            provider: provider,
            clipExtractor: AudioBenchmarkWAVClipExtractor(
                temporaryRootURL: fixture.tempRoot,
                fileManager: recorder,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            monotonicSeconds: { 10 }
        )

        let aggregate = try await runner.run(
            cases: [runCase],
            configuration: configuration,
            outputDirectoryURL: fixture.outputRoot
        )

        XCTAssertEqual(aggregate.targetCount, 1)
        XCTAssertEqual(aggregate.successCount, 1)
        XCTAssertEqual(aggregate.failureCount, 0)
        XCTAssertEqual(aggregate.cer.mean, 0)
        XCTAssertEqual(aggregate.der.mean, 0)
        let providerInvocationCount = await provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 1)
        let accesses = recorder.accessedPaths
        XCTAssertEqual(accesses.filter { $0.hasSuffix("source-index.jsonl") }.count, 1)
        XCTAssertEqual(accesses.filter { $0.hasSuffix("ARV0-E01.json") }.count, 1)
        XCTAssertGreaterThanOrEqual(accesses.filter { $0.hasSuffix("development.wav") }.count, 1)
        XCTAssertFalse(accesses.contains { $0.hasSuffix("manifest.jsonl") })
        XCTAssertFalse(accesses.contains { $0.hasSuffix("ARV0-H01.json") })
        XCTAssertFalse(accesses.contains { $0.hasSuffix("holdout.wav") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.tempRoot.path), [])

        let reportData = try FileManager.default.contentsOfDirectory(
            at: fixture.outputRoot,
            includingPropertiesForKeys: nil
        ).reduce(into: Data()) { bytes, url in
            bytes.append(try Data(contentsOf: url))
        }
        let reportText = String(decoding: reportData, as: UTF8.self)
        for forbidden in ["가", "speaker_0", fixture.root.path, "transcript", "audio_path"] {
            XCTAssertFalse(reportText.contains(forbidden), "report leaked \(forbidden)")
        }
    }
}

private struct SyntheticAuthorizedCase: Decodable {
    let sourceAudioPath: String
    let startFrame: Int64
    let frameCount: UInt32
    let durationSeconds: Double
    let reference: [SyntheticReferenceSegment]

    private enum CodingKeys: String, CodingKey {
        case sourceAudioPath = "source_audio_path"
        case startFrame = "start_frame"
        case frameCount = "frame_count"
        case durationSeconds = "duration_seconds"
        case reference
    }
}

private struct SyntheticReferenceSegment: Decodable {
    let startSeconds: Double
    let endSeconds: Double
    let speaker: String
    let textNormalized: String

    private enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case speaker
        case textNormalized = "text_normalized"
    }
}

private final class SyntheticAudioFixture {
    let root: URL
    let datasetRoot: URL
    let sourceRoot: URL
    let outputRoot: URL
    let tempRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("haena-audio-e2e-\(UUID().uuidString)", isDirectory: true)
        datasetRoot = root.appendingPathComponent("audio-robustness-v0", isDirectory: true)
        sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        outputRoot = root.appendingPathComponent("output", isDirectory: true)
        tempRoot = root.appendingPathComponent("temp", isDirectory: true)
        let goldRoot = datasetRoot.appendingPathComponent("gold", isDirectory: true)
        let wavRoot = sourceRoot.appendingPathComponent("wav", isDirectory: true)
        try FileManager.default.createDirectory(at: goldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wavRoot, withIntermediateDirectories: true)

        let index = """
        {"schema_version":"haena-benchmark-v0.1","benchmark":"audio-robustness-v0","case_id":"ARV0-E01","split":"development","review_status":"source_aligned_label","case_path":"gold/ARV0-E01.json"}
        {"schema_version":"haena-benchmark-v0.1","benchmark":"audio-robustness-v0","case_id":"ARV0-H01","split":"sealed_holdout","review_status":"source_aligned_label","case_path":"gold/ARV0-H01.json"}
        """
        try Data((index + "\n").utf8).write(to: datasetRoot.appendingPathComponent("source-index.jsonl"))
        try Data("must-not-be-read".utf8).write(to: datasetRoot.appendingPathComponent("manifest.jsonl"))
        let developmentGold = """
        {"source_audio_path":"wav/development.wav","start_frame":0,"frame_count":8000,"duration_seconds":1,"reference":[{"start_seconds":0,"end_seconds":1,"speaker":"B","text_normalized":"가"}]}
        """
        try Data(developmentGold.utf8).write(to: goldRoot.appendingPathComponent("ARV0-E01.json"))
        try Data("must-not-be-read".utf8).write(to: goldRoot.appendingPathComponent("ARV0-H01.json"))
        try Self.writeSyntheticWAV(to: wavRoot.appendingPathComponent("development.wav"))
        try Self.writeSyntheticWAV(to: wavRoot.appendingPathComponent("holdout.wav"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
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
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class SyntheticRecordingFileManager: FileManager {
    private let lock = NSLock()
    private var paths: [String] = []

    var accessedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override func contents(atPath path: String) -> Data? {
        lock.lock()
        paths.append(path)
        lock.unlock()
        return super.contents(atPath: path)
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.lock()
        paths.append(path)
        lock.unlock()
        return super.fileExists(atPath: path)
    }
}
