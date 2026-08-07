import Foundation

// MARK: - Capabilities

/// What a transcription backend can actually do, declared rather than assumed.
///
/// Every field is a fact the adapter knows about its own provider. A capability that is not
/// offered is `false`, and a limit the provider does not publish is nil — never a guessed
/// number, because a wrong limit here would be enforced against the user's file as if it were real.
struct TranscriptionCapabilities: Equatable, Sendable {
    let fileTranscription: Bool
    let segmentTimestamps: Bool
    let speakerDiarization: Bool
    let wordTimestamps: Bool
    /// Provider-published upload ceiling in bytes. Nil when the provider publishes none.
    let maximumFileBytes: Int?
}

// MARK: - Request

/// One file handed to a provider for transcription.
///
/// Carries the app's own stored copy, never the user's original path: by the time a request
/// exists the original has already been copied into app-managed storage, and a provider retry
/// must not depend on a file the user may have since moved or deleted.
struct TranscriptionRequest: Equatable, Sendable {
    let fileURL: URL
    /// Used for the multipart filename only, so the provider sees a sensible extension.
    let fileName: String
    let byteSize: Int
}

// MARK: - Result

/// One utterance-level span of transcribed speech.
///
/// `speakerLabel` is the provider's own opaque label (`"speaker_1"`, `"A"`, …), deliberately not
/// resolved to a person here. Mapping labels to `Participant`s is the domain's job, and no
/// provider is trusted to name a real human being.
struct TranscriptionSegment: Equatable, Sendable {
    let text: String
    /// Seconds from the start of the audio. Nil when the provider gave no timing.
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let speakerLabel: String?
}

/// One completed transcription run.
struct TranscriptionResult: Equatable, Sendable {
    let segments: [TranscriptionSegment]
    let metadata: ModelRunMetadata
}

// MARK: - Provider

/// The seam between HAE.NA's domain and whatever service turns audio into text.
///
/// Mirrors `WorkStateExtractor`: only Foundation and HAE.NA types appear in the signature, so
/// nothing about endpoints, multipart bodies, or response DTOs can leak past an adapter. Phase 0
/// ships exactly one implementation (OpenAI); the protocol exists so the second one does not
/// require touching the services or views that consume this.
protocol TranscriptionProvider: Sendable {
    var capabilities: TranscriptionCapabilities { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

/// Failure modes every transcription provider maps onto.
///
/// As with `WorkStateExtractionError`, no case carries provider-supplied free text: an error must
/// never be able to smuggle an API key or a slice of the user's meeting into a log or the UI.
enum TranscriptionError: Error, Equatable, Sendable {
    case missingCredential
    case invalidConfiguration
    case unauthorized
    case rateLimited
    case serverError(statusCode: Int)
    case requestRejected(statusCode: Int)
    case timedOut
    case networkUnavailable
    /// The provider answered successfully but produced nothing usable. Treated as a failure, not
    /// as an empty success — saving a meeting with no transcript would look like data loss.
    case emptyTranscript
    case malformedResponse
}
