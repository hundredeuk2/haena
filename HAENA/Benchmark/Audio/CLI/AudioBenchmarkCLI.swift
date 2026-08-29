import AVFoundation
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum AudioBenchmarkCLI {
    private enum ExitCode {
        static let success: Int32 = 0
        static let caseFailures: Int32 = 1
        static let usage: Int32 = 2
    }

    static func run(arguments: [String]) async -> Int32 {
        if AudioBenchmarkCommandLine.wantsHelp(arguments) {
            print(AudioBenchmarkCommandLine.usage)
            return ExitCode.success
        }

        let options: AudioBenchmarkCommandLine.Options
        do {
            options = try AudioBenchmarkCommandLine.parse(arguments)
        } catch {
            printError("Audio Benchmark 인자를 해석할 수 없습니다.")
            print(AudioBenchmarkCommandLine.usage)
            return ExitCode.usage
        }

        // This task implements the adapter but deliberately does not wire a live execution path.
        // The refusal happens before discovery, source access, output creation, or credential use.
        guard options.provider == .offlineFake else {
            printError("외부 STT 실행은 별도 provider·전송·비용 승인이 있을 때까지 비활성화되어 있습니다.")
            return ExitCode.usage
        }

        let store = AudioBenchmarkCaseStore(
            datasetRoot: URL(fileURLWithPath: options.datasetRoot, isDirectory: true),
            sourceAssetRoot: URL(fileURLWithPath: options.sourceRoot, isDirectory: true)
        )

        let entries: [AudioBenchmarkAuthorizedEntry]
        do {
            entries = try store.authorizedEntries(for: options.selection)
        } catch AudioBenchmarkIsolationError.sealedHoldoutLocked {
            printError("봉인된 Audio holdout은 실행하거나 열 수 없습니다.")
            return ExitCode.usage
        } catch {
            printError("Audio discovery index를 검증하거나 development 대상을 승인하지 못했습니다.")
            return ExitCode.usage
        }

        let runCases: [AudioBenchmarkRunCase]
        do {
            runCases = try entries.map { entry in
                let data = try store.caseData(for: entry)
                let payload = try JSONDecoder().decode(AuthorizedAudioCase.self, from: data)
                return try payload.runCase(entry: entry, store: store)
            }
        } catch {
            printError("승인된 development case를 준비하지 못했습니다.")
            return ExitCode.usage
        }

        let provider = OfflineEmptyAudioBenchmarkProvider()
        let configuration = AudioBenchmarkRunConfiguration(
            metricSchemaVersion: AudioBenchmarkScore.metricSchemaVersion,
            providerID: provider.providerID,
            modelID: provider.modelID,
            caseIDs: runCases.map(\.caseID)
        )
        let runner = AudioBenchmarkRunner(provider: provider)

        do {
            let report = try await runner.run(
                cases: runCases,
                configuration: configuration,
                outputDirectoryURL: URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
            )
            print("audio benchmark     : \(report.benchmark)")
            print("cases               : \(report.targetCount)")
            print("succeeded / failed  : \(report.successCount) / \(report.failureCount)")
            print("provider            : offline fake (network 0)")
            print("주의: fake provider metric은 파이프라인 검증값이며 STT 성능 수치가 아닙니다.")
            return report.failureCount == 0 ? ExitCode.success : ExitCode.caseFailures
        } catch AudioBenchmarkRunError.sealedHoldoutDenied {
            printError("봉인된 Audio holdout은 실행하거나 열 수 없습니다.")
            return ExitCode.usage
        } catch {
            printError("Audio Benchmark 실행을 완료하지 못했습니다.")
            return ExitCode.usage
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Offline provider that observes only the extracted clip capability and returns an empty,
/// timestamp-valid recognition result. It never sees reference text and never opens a socket.
private struct OfflineEmptyAudioBenchmarkProvider: AudioBenchmarkProvider {
    let providerID = "offline-fake"
    let modelID = "empty-recognition-v0"

    func transcribe(
        audioFileURL: URL,
        expectedAudioDurationSeconds: Double
    ) async throws -> PredictedTranscript {
        guard audioFileURL.lastPathComponent == "clip.wav",
              FileManager.default.fileExists(atPath: audioFileURL.path),
              expectedAudioDurationSeconds.isFinite,
              expectedAudioDurationSeconds > 0 else {
            throw AudioBenchmarkProviderError.invalidResponse
        }
        return PredictedTranscript(
            providerID: providerID,
            modelID: modelID,
            processingDurationSeconds: 0,
            audioDurationSeconds: expectedAudioDurationSeconds,
            segments: []
        )
    }
}

/// Decoder for content that is reachable only after a development index entry is authorized.
/// Extra corpus fields are intentionally ignored and no decoded value is itself Codable, keeping
/// source paths and reference text out of the report type graph.
struct AuthorizedAudioCase: Decodable {
    static let requiredMetricScope: Set<String> = [
        "cer",
        "speaker_count_error",
        "der",
        "speaker_attribution_accuracy",
        "target_speaker_b_f1",
        "speaker_attributed_cer",
        "real_time_factor",
    ]

    struct Source: Decodable { let audioPath: String }
    struct Clip: Decodable {
        let durationSeconds: Double
        let startFrame: Int64
        let endFrame: Int64
    }
    struct AudioFormat: Decodable {
        let channels: UInt32
        let sampleRateHz: Double
        let sampleWidthBytes: UInt32
        let frameCount: Int64
        let compression: String
    }
    struct Gold: Decodable {
        let status: String
        let transcript: [Segment]
        let metricScope: [String]

        private enum CodingKeys: String, CodingKey {
            case status
            case transcript
            case metricScope = "metric_scope"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            transcript = try container.decode([Segment].self, forKey: .transcript)
            metricScope = try container.decode([String].self, forKey: .metricScope)
            guard metricScope.count == AuthorizedAudioCase.requiredMetricScope.count,
                  Set(metricScope) == AuthorizedAudioCase.requiredMetricScope else {
                throw DecodingError.dataCorruptedError(
                    forKey: .metricScope,
                    in: container,
                    debugDescription: "metric_scope must contain each required v0 metric exactly once"
                )
            }
        }
    }
    struct Segment: Decodable {
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

    let schemaVersion: String
    let benchmark: String
    let caseID: String
    let split: AudioBenchmarkSplit
    let reviewStatus: String
    let targetSpeaker: String
    let source: Source
    let clip: Clip
    let audioFormat: AudioFormat
    let gold: Gold

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case benchmark
        case caseID = "case_id"
        case split
        case reviewStatus = "review_status"
        case targetSpeaker = "target_speaker"
        case source
        case clip
        case audioFormat = "audio_format"
        case gold
    }

    func runCase(
        entry: AudioBenchmarkAuthorizedEntry,
        store: AudioBenchmarkCaseStore
    ) throws -> AudioBenchmarkRunCase {
        guard schemaVersion == AudioBenchmarkCaseStore.schemaVersion,
              benchmark == AudioBenchmarkCaseStore.benchmark,
              caseID == entry.caseID,
              reviewStatus == "source_aligned_label",
              gold.status == "source_aligned_label",
              targetSpeaker == "B",
              clip.startFrame >= 0,
              clip.endFrame > clip.startFrame,
              clip.endFrame <= audioFormat.frameCount,
              audioFormat.channels > 0,
              audioFormat.sampleRateHz.isFinite,
              audioFormat.sampleRateHz > 0,
              (1...4).contains(audioFormat.sampleWidthBytes),
              audioFormat.compression == "NONE" else {
            throw AudioBenchmarkIsolationError.malformedSourceIndexLine(lineNumber: 0)
        }
        let frameCount64 = clip.endFrame - clip.startFrame
        guard let frameCount = AVAudioFrameCount(exactly: frameCount64) else {
            throw AudioBenchmarkIsolationError.invalidRelativePath
        }
        let exactDuration = Double(frameCount) / audioFormat.sampleRateHz
        let tolerance = max(1 / audioFormat.sampleRateHz, 0.000_001)
        guard clip.durationSeconds.isFinite,
              abs(clip.durationSeconds - exactDuration) <= tolerance else {
            throw AudioBenchmarkIsolationError.invalidRelativePath
        }
        let sourceURL = try store.authorizedSourceAssetURL(relativePath: source.audioPath, for: entry)
        let reference = AudioBenchmarkReferenceTranscript(
            audioDurationSeconds: exactDuration,
            targetSpeakerLabel: targetSpeaker,
            segments: gold.transcript.map {
                AudioBenchmarkReferenceSegment(
                    startTimeSeconds: $0.startSeconds,
                    endTimeSeconds: $0.endSeconds,
                    speakerLabel: $0.speaker,
                    textNormalized: $0.textNormalized
                )
            }
        )
        return AudioBenchmarkRunCase(
            caseID: caseID,
            // The source index issued `entry` only after development authorization. Its split is
            // authoritative: metadata-only holdout rotation intentionally does not rewrite the
            // transcript-bearing gold payload, whose historical split may therefore be stale.
            split: .development,
            sourceClip: AudioBenchmarkSourceClip(
                sourceWAVURL: sourceURL,
                startFrame: AVAudioFramePosition(clip.startFrame),
                frameCount: frameCount,
                expectedFormat: AudioBenchmarkWAVFormat(
                    sampleRate: audioFormat.sampleRateHz,
                    channelCount: audioFormat.channels,
                    bitDepth: audioFormat.sampleWidthBytes * 8,
                    sampleEncoding: audioFormat.sampleWidthBytes == 1 ? .unsignedInteger : .signedInteger
                )
            ),
            reference: reference
        )
    }
}

private extension AuthorizedAudioCase.Source {
    enum CodingKeys: String, CodingKey { case audioPath = "audio_path" }
}

private extension AuthorizedAudioCase.Clip {
    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
    }
}

private extension AuthorizedAudioCase.AudioFormat {
    enum CodingKeys: String, CodingKey {
        case channels
        case sampleRateHz = "sample_rate_hz"
        case sampleWidthBytes = "sample_width_bytes"
        case frameCount = "frame_count"
        case compression
    }
}
