import Foundation

/// A `TranscriptionProvider` that calls nothing and returns the same two-speaker transcript every
/// time, so UI-test launches can exercise the import flow without a network or an API key.
///
/// Wired in **only** at the app's assembly point when launched under UI test, and never
/// substituted for the real provider when it fails — a user must never be shown an invented
/// transcript because an API call errored.
struct DeterministicTranscriptionProvider: TranscriptionProvider {
    let modelID: String
    let now: @Sendable () -> Date

    init(modelID: String = "deterministic-transcribe-v1", now: @escaping @Sendable () -> Date = Date.init) {
        self.modelID = modelID
        self.now = now
    }

    var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            fileTranscription: true,
            segmentTimestamps: true,
            speakerDiarization: true,
            wordTimestamps: false,
            maximumFileBytes: AudioFileValidator.maximumFileBytes
        )
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(
            segments: [
                TranscriptionSegment(
                    text: "우리는 2월 출시로 가기로 했습니다.",
                    startTime: 0,
                    endTime: 4,
                    speakerLabel: "speaker_1"
                ),
                TranscriptionSegment(
                    text: "지표 정의는 아직 정하지 못했습니다.",
                    startTime: 4,
                    endTime: 8,
                    speakerLabel: "speaker_2"
                )
            ],
            metadata: ModelRunMetadata(
                provider: .deterministic,
                modelID: modelID,
                completedAt: now()
            )
        )
    }
}
