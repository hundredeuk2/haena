import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum AudioBenchmarkProviderError: String, Error, Codable, Equatable, Sendable {
    case missingCredential
    case unauthorized
    case rateLimited
    case timeout
    case networkUnavailable
    case rejected
    case unavailable
    case invalidResponse
}

/// A benchmark provider receives only the anonymous, temporary clip and its duration. Dataset paths,
/// case ids, reference text and speaker mappings never cross this seam.
protocol AudioBenchmarkProvider: Sendable {
    var providerID: String { get }
    var modelID: String { get }

    func transcribe(
        audioFileURL: URL,
        expectedAudioDurationSeconds: Double
    ) async throws -> PredictedTranscript
}

/// A scripted provider used to verify the complete runner without opening a socket or loading a
/// credential. The actor makes invocation order deterministic even if a future caller is async.
actor DeterministicAudioBenchmarkFakeProvider: AudioBenchmarkProvider {
    enum Response: Equatable, Sendable {
        case prediction(PredictedTranscript)
        case failure(AudioBenchmarkProviderError)
    }

    nonisolated let providerID: String
    nonisolated let modelID: String
    private let responses: [Response]
    private var nextResponseIndex = 0

    init(
        providerID: String = "offline-fake",
        modelID: String = "deterministic-v0",
        responses: [Response]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.responses = responses
    }

    func transcribe(
        audioFileURL: URL,
        expectedAudioDurationSeconds: Double
    ) async throws -> PredictedTranscript {
        guard audioFileURL.lastPathComponent == "clip.wav",
              FileManager.default.fileExists(atPath: audioFileURL.path),
              expectedAudioDurationSeconds.isFinite,
              expectedAudioDurationSeconds > 0,
              nextResponseIndex < responses.count else {
            throw AudioBenchmarkProviderError.invalidResponse
        }

        let response = responses[nextResponseIndex]
        nextResponseIndex += 1
        switch response {
        case .prediction(let prediction):
            return prediction
        case .failure(let error):
            throw error
        }
    }

    func invocationCount() -> Int {
        nextResponseIndex
    }
}

/// Adapts the app's existing transcription seam without exposing provider response DTOs to the
/// benchmark. Constructing this adapter does not select or invoke a live provider; the caller must
/// still explicitly supply one and satisfy the harness's network/data-transfer policy.
struct AppTranscriptionAudioBenchmarkProvider: AudioBenchmarkProvider {
    let providerID: String
    let modelID: String
    let provider: any TranscriptionProvider

    init(providerID: String, modelID: String, provider: any TranscriptionProvider) {
        self.providerID = providerID
        self.modelID = modelID
        self.provider = provider
    }

    func transcribe(
        audioFileURL: URL,
        expectedAudioDurationSeconds: Double
    ) async throws -> PredictedTranscript {
        guard provider.capabilities.fileTranscription,
              provider.capabilities.segmentTimestamps,
              provider.capabilities.speakerDiarization,
              expectedAudioDurationSeconds.isFinite,
              expectedAudioDurationSeconds > 0 else {
            throw AudioBenchmarkProviderError.invalidResponse
        }

        let byteSize: Int
        do {
            let values = try audioFileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw AudioBenchmarkProviderError.invalidResponse
            }
            byteSize = size
        } catch let error as AudioBenchmarkProviderError {
            throw error
        } catch {
            throw AudioBenchmarkProviderError.invalidResponse
        }

        let result: TranscriptionResult
        do {
            result = try await provider.transcribe(
                TranscriptionRequest(fileURL: audioFileURL, fileName: "clip.wav", byteSize: byteSize)
            )
        } catch let error as TranscriptionError {
            throw Self.map(error)
        } catch {
            throw AudioBenchmarkProviderError.unavailable
        }

        guard result.metadata.provider.rawValue == providerID,
              result.metadata.modelID == modelID,
              !result.segments.isEmpty else {
            throw AudioBenchmarkProviderError.invalidResponse
        }

        let segments = try result.segments.map { segment -> PredictedSegment in
            guard let start = segment.startTime,
                  let end = segment.endTime,
                  start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start,
                  end <= expectedAudioDurationSeconds,
                  let speaker = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speaker.isEmpty else {
                throw AudioBenchmarkProviderError.invalidResponse
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AudioBenchmarkProviderError.invalidResponse
            }
            return PredictedSegment(
                startTimeSeconds: start,
                endTimeSeconds: end,
                predictedSpeakerLabel: speaker,
                text: text
            )
        }

        // The runner overwrites processingDurationSeconds with its own wall-clock measurement,
        // including provider/network wait. Zero here prevents provider-shaped timing from being
        // mistaken for the benchmark's RTF measurement before that normalization step.
        return PredictedTranscript(
            providerID: providerID,
            modelID: modelID,
            processingDurationSeconds: 0,
            audioDurationSeconds: expectedAudioDurationSeconds,
            segments: segments
        )
    }

    private static func map(_ error: TranscriptionError) -> AudioBenchmarkProviderError {
        switch error {
        case .missingCredential:
            return .missingCredential
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .timedOut:
            return .timeout
        case .networkUnavailable:
            return .networkUnavailable
        case .requestRejected:
            return .rejected
        case .invalidConfiguration, .emptyTranscript, .malformedResponse:
            return .invalidResponse
        case .serverError:
            return .unavailable
        }
    }
}
