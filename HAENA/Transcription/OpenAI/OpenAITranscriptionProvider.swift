import Foundation

/// Everything the transcription adapter needs except the credential.
///
/// Separate from `OpenAIConfiguration` because these are different endpoints with different
/// models, timeouts, and limits; the *credential rule* is shared, and that is the part reused —
/// `OpenAIConfiguration.apiKey(from:)` stays the app's single source of API keys.
struct OpenAITranscriptionConfiguration: Equatable, Sendable {
    /// The single source of truth for which transcription model HAE.NA asks for.
    static let defaultModelID = "gpt-4o-transcribe-diarize"
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    var endpoint: URL
    var modelID: String
    /// Generous on purpose: a 10-minute recording is a multi-megabyte upload plus server-side
    /// processing, and the 60s default used for text extraction would time out a healthy request.
    var requestTimeout: TimeInterval
    /// Retries *after* the first attempt. Lower than the extraction adapter's on purpose — each
    /// retry re-uploads the whole file, so a persistent outage must not cost the user three
    /// full uploads.
    var maxRetries: Int
    var retryDelay: TimeInterval

    init(
        endpoint: URL = OpenAITranscriptionConfiguration.defaultEndpoint,
        modelID: String = OpenAITranscriptionConfiguration.defaultModelID,
        requestTimeout: TimeInterval = 300,
        maxRetries: Int = 1,
        retryDelay: TimeInterval = 1
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }
}

/// `TranscriptionProvider` backed by OpenAI's audio transcription endpoint.
///
/// Everything OpenAI-specific — the endpoint, the multipart body, the response DTO, the model ID —
/// stops at this file, exactly as `OpenAIWorkStateExtractor` does for the Responses API.
///
/// Deliberately sends **no `prompt` and no keyword hints**: `gpt-4o-transcribe-diarize` does not
/// support them, so any hinting would be silently ignored while creating the impression that
/// Korean-English mixing had been handled. See `HANDOFF_B.md` (X6).
struct OpenAITranscriptionProvider: TranscriptionProvider {
    private let configuration: OpenAITranscriptionConfiguration
    private let apiKeyProvider: @Sendable () -> String?
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let makeBoundary: @Sendable () -> String

    init(
        configuration: OpenAITranscriptionConfiguration = OpenAITranscriptionConfiguration(),
        apiKeyProvider: @escaping @Sendable () -> String? = { OpenAIConfiguration.apiKey() },
        transport: (any HTTPTransport)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        makeBoundary: @escaping @Sendable () -> String = { "haena-\(UUID().uuidString)" }
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport ?? URLSessionHTTPTransport(requestTimeout: configuration.requestTimeout)
        self.now = now
        self.makeBoundary = makeBoundary
    }

    /// Word timestamps are `false` rather than unknown: this model returns segment-level timings
    /// only, and HAE.NA stores utterance-level segments, so word timings are neither available
    /// nor needed.
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
        // Resolved per call, not at init: the app must launch, and every other feature must keep
        // working, when no key is configured.
        guard let apiKey = apiKeyProvider() else {
            throw TranscriptionError.missingCredential
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: request.fileURL)
        } catch {
            throw TranscriptionError.invalidConfiguration
        }

        let urlRequest = makeRequest(for: request, audioData: audioData, apiKey: apiKey)
        let (data, response) = try await send(urlRequest)
        try Self.validate(statusCode: response.statusCode)

        let reply: OpenAITranscriptionReply
        do {
            reply = try JSONDecoder().decode(OpenAITranscriptionReply.self, from: data)
        } catch {
            // The underlying error is dropped rather than wrapped: a decoding failure's
            // description can quote the payload it choked on, which is the user's meeting.
            throw TranscriptionError.malformedResponse
        }

        if reply.error != nil {
            throw TranscriptionError.malformedResponse
        }

        let segments = Self.segments(from: reply)
        // A 200 with nothing usable in it is a failure, not an empty success. Saving a meeting
        // with no transcript would look to the user like their audio was silently lost.
        guard !segments.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        return TranscriptionResult(
            segments: segments,
            metadata: ModelRunMetadata(
                provider: .openAI,
                modelID: configuration.modelID,
                completedAt: now()
            )
        )
    }

    // MARK: - Request

    private func makeRequest(
        for request: TranscriptionRequest,
        audioData: Data,
        apiKey: String
    ) -> URLRequest {
        var form = MultipartFormData(boundary: makeBoundary())
        form.addField(name: "model", value: configuration.modelID)
        form.addField(name: "response_format", value: "diarized_json")
        // Required for audio longer than 30 seconds on this model. `auto` lets the server pick
        // the split points; HAE.NA does not split audio itself.
        form.addField(name: "chunking_strategy", value: "auto")
        form.addFile(
            name: "file",
            fileName: request.fileName,
            contentType: MultipartFormData.contentType(
                forFileExtension: (request.fileName as NSString).pathExtension
            ),
            data: audioData
        )

        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.requestTimeout
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = form.encoded()
        return urlRequest
    }

    // MARK: - Sending

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let result: (data: Data, response: HTTPURLResponse)
            do {
                let (data, response) = try await transport.send(request)
                result = (data, response)
            } catch let error as TranscriptionError {
                throw error
            } catch let error as WorkStateExtractionError {
                // `URLSessionHTTPTransport` is shared with the extraction adapter and reports a
                // non-HTTP response using that type; translate rather than leak it.
                throw error == .malformedResponse
                    ? TranscriptionError.malformedResponse
                    : TranscriptionError.networkUnavailable
            } catch let error as URLError {
                throw Self.mapped(error)
            } catch {
                throw TranscriptionError.networkUnavailable
            }

            // Retried only where a retry is safe and likely to help: the request was never
            // accepted, so re-sending cannot duplicate work on the provider's side.
            guard Self.isRetryable(statusCode: result.response.statusCode), attempt < configuration.maxRetries else {
                return result
            }

            attempt += 1
            if configuration.retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
            }
        }
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func validate(statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 401, 403:
            throw TranscriptionError.unauthorized
        case 408:
            throw TranscriptionError.timedOut
        case 429:
            throw TranscriptionError.rateLimited
        case 500...599:
            throw TranscriptionError.serverError(statusCode: statusCode)
        default:
            throw TranscriptionError.requestRejected(statusCode: statusCode)
        }
    }

    private static func mapped(_ error: URLError) -> TranscriptionError {
        switch error.code {
        case .timedOut:
            return .timedOut
        default:
            return .networkUnavailable
        }
    }

    // MARK: - Mapping

    /// Keeps only segments that carry actual speech. A response whose `segments` array is absent
    /// entirely is treated the same as one that is empty — both mean "no usable transcript" — and
    /// the top-level `text` is deliberately *not* used as a fallback, because silently producing
    /// one untimed, speaker-less segment would hide that diarization did not happen.
    private static func segments(from reply: OpenAITranscriptionReply) -> [TranscriptionSegment] {
        (reply.segments ?? []).compactMap { segment in
            let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            let speakerLabel = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptionSegment(
                text: text,
                startTime: segment.start,
                endTime: segment.end,
                speakerLabel: (speakerLabel?.isEmpty ?? true) ? nil : speakerLabel
            )
        }
    }
}
