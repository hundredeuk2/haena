import XCTest
@testable import HAENA

/// Drives every branch of the transcription adapter through `RecordingHTTPTransport`, so request
/// construction, status handling, and response mapping are all verified without an API key, a
/// network connection, or a real request ever leaving the machine.
final class OpenAITranscriptionProviderTests: XCTestCase {
    private var directory: URL!
    private var audioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try AudioTestSupport.makeTemporaryDirectory(self)
        audioURL = try AudioTestSupport.writeFile(named: "meeting.m4a", byteCount: 32, in: directory)
    }

    private var request: TranscriptionRequest {
        TranscriptionRequest(fileURL: audioURL, fileName: "meeting.m4a", byteSize: 32)
    }

    private func makeProvider(
        transport: RecordingHTTPTransport,
        apiKey: String? = "test-api-key-THIS-MUST-NOT-LEAK"
    ) -> OpenAITranscriptionProvider {
        OpenAITranscriptionProvider(
            configuration: OpenAITranscriptionConfiguration(maxRetries: 1, retryDelay: 0),
            apiKeyProvider: { apiKey },
            transport: transport,
            now: { TestFixtures.fixedDate },
            makeBoundary: { "test-boundary" }
        )
    }

    private func transcriptionError(
        body: Data = Data(),
        statusCode: Int = 200,
        apiKey: String? = "test-api-key-THIS-MUST-NOT-LEAK"
    ) async -> TranscriptionError? {
        let transport = RecordingHTTPTransport([.status(statusCode, body: body)])
        do {
            _ = try await makeProvider(transport: transport, apiKey: apiKey).transcribe(request)
            return nil
        } catch let error as TranscriptionError {
            return error
        } catch {
            return nil
        }
    }

    private static func responseBody(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Capabilities

    /// Capabilities must state what this model actually does — word timestamps are absent, and
    /// claiming otherwise would let callers ask for timings that never arrive.
    func testCapabilitiesDeclareSegmentsAndSpeakersButNotWords() {
        let capabilities = OpenAITranscriptionProvider().capabilities
        XCTAssertTrue(capabilities.fileTranscription)
        XCTAssertTrue(capabilities.segmentTimestamps)
        XCTAssertTrue(capabilities.speakerDiarization)
        XCTAssertFalse(capabilities.wordTimestamps)
        XCTAssertEqual(capabilities.maximumFileBytes, AudioFileValidator.maximumFileBytes)
    }

    // MARK: - Request construction

    func testRequestCarriesModelDiarizedFormatChunkingAndTheFile() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요"}]}"#))
        ])
        _ = try await makeProvider(transport: transport).transcribe(request)

        let sent = await transport.sentRequests
        XCTAssertEqual(sent.count, 1)
        let urlRequest = try XCTUnwrap(sent.first)

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=test-boundary"
        )
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-api-key-THIS-MUST-NOT-LEAK"
        )

        let body = try XCTUnwrap(urlRequest.httpBody.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(body.contains(#"name="model""#))
        XCTAssertTrue(body.contains("gpt-4o-transcribe-diarize"))
        XCTAssertTrue(body.contains(#"name="response_format""#))
        XCTAssertTrue(body.contains("diarized_json"))
        // Required for audio longer than 30 seconds on this model.
        XCTAssertTrue(body.contains(#"name="chunking_strategy""#))
        XCTAssertTrue(body.contains("auto"))
        XCTAssertTrue(body.contains(#"name="file"; filename="meeting.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(body.hasSuffix("--test-boundary--\r\n"))
    }

    /// `gpt-4o-transcribe-diarize` ignores prompts and keyword hints, so sending one would create
    /// a false impression that Korean-English mixing had been steered.
    func testRequestSendsNoPromptOrLanguageHint() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요"}]}"#))
        ])
        _ = try await makeProvider(transport: transport).transcribe(request)

        let sent = await transport.sentRequests
        let body = try XCTUnwrap(sent.first?.httpBody.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertFalse(body.contains(#"name="prompt""#))
        XCTAssertFalse(body.contains(#"name="language""#))
        XCTAssertFalse(body.contains(#"name="vocabulary""#))
    }

    func testTimeoutIsExplicitAndLongEnoughForALongRecording() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요"}]}"#))
        ])
        _ = try await makeProvider(transport: transport).transcribe(request)

        let sent = await transport.sentRequests
        let timeout = try XCTUnwrap(sent.first?.timeoutInterval)
        XCTAssertEqual(timeout, 300)
    }

    // MARK: - Credentials

    func testMissingCredentialFailsBeforeAnyRequestIsSent() async {
        let transport = RecordingHTTPTransport([.status(200, body: Data())])
        let provider = makeProvider(transport: transport, apiKey: nil)

        do {
            _ = try await provider.transcribe(request)
            XCTFail("Expected a missing-credential failure.")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .missingCredential)
        }
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - Status mapping

    func testUnauthorizedIsReportedDistinctly() async {
        let error = await transcriptionError(statusCode: 401)
        XCTAssertEqual(error, .unauthorized)
    }

    func testForbiddenIsReportedAsUnauthorized() async {
        let error = await transcriptionError(statusCode: 403)
        XCTAssertEqual(error, .unauthorized)
    }

    func testRateLimitIsReportedDistinctly() async {
        let error = await transcriptionError(statusCode: 429)
        XCTAssertEqual(error, .rateLimited)
    }

    func testServerErrorCarriesItsStatusCode() async {
        let error = await transcriptionError(statusCode: 503)
        XCTAssertEqual(error, .serverError(statusCode: 503))
    }

    func testUnexpectedClientErrorIsReportedAsRejected() async {
        let error = await transcriptionError(statusCode: 413)
        XCTAssertEqual(error, .requestRejected(statusCode: 413))
    }

    func testTimeoutIsReportedDistinctly() async {
        let transport = RecordingHTTPTransport([.failure(URLError(.timedOut))])
        do {
            _ = try await makeProvider(transport: transport).transcribe(request)
            XCTFail("Expected a timeout failure.")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .timedOut)
        }
    }

    func testOfflineIsReportedAsNetworkUnavailable() async {
        let transport = RecordingHTTPTransport([.failure(URLError(.notConnectedToInternet))])
        do {
            _ = try await makeProvider(transport: transport).transcribe(request)
            XCTFail("Expected a network failure.")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .networkUnavailable)
        }
    }

    // MARK: - Retry policy

    func testServerErrorIsRetriedUpToTheConfiguredLimit() async {
        let transport = RecordingHTTPTransport([.status(500, body: Data())])
        _ = try? await makeProvider(transport: transport).transcribe(request)

        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 2, "One initial attempt plus one retry.")
    }

    /// A 401 will not become a 200 by asking again, and each retry re-uploads the whole file.
    func testUnauthorizedIsNotRetried() async {
        let transport = RecordingHTTPTransport([.status(401, body: Data())])
        _ = try? await makeProvider(transport: transport).transcribe(request)

        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Body handling

    func testMalformedJSONIsReportedAsMalformed() async {
        let error = await transcriptionError(body: Data("{not json".utf8))
        XCTAssertEqual(error, .malformedResponse)
    }

    func testErrorBodyOnA200IsReportedAsMalformed() async {
        let error = await transcriptionError(
            body: Self.responseBody(#"{"error":{"message":"boom","type":"server_error"}}"#)
        )
        XCTAssertEqual(error, .malformedResponse)
    }

    /// A 200 with nothing usable is a failure: saving a transcript-less meeting would look to
    /// the user like their audio was silently lost.
    func testEmptySegmentsArrayOnA200IsAFailure() async {
        let error = await transcriptionError(body: Self.responseBody(#"{"segments":[]}"#))
        XCTAssertEqual(error, .emptyTranscript)
    }

    func testMissingSegmentsKeyOnA200IsAFailure() async {
        let error = await transcriptionError(body: Self.responseBody(#"{"text":"안녕하세요"}"#))
        XCTAssertEqual(
            error,
            .emptyTranscript,
            "Top-level text must not be used as a fallback — it would hide that diarization did not happen."
        )
    }

    func testSegmentsWithOnlyWhitespaceAreDroppedAndCountAsEmpty() async {
        let error = await transcriptionError(
            body: Self.responseBody(#"{"segments":[{"text":"   "},{"text":""}]}"#)
        )
        XCTAssertEqual(error, .emptyTranscript)
    }

    // MARK: - Segment mapping

    func testMapsTextTimingsAndSpeakerLabels() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody("""
            {"segments":[
              {"text":"안녕하세요","start":0.0,"end":2.5,"speaker":"speaker_1"},
              {"text":"네 반갑습니다","start":2.5,"end":5.0,"speaker":"speaker_2"}
            ]}
            """))
        ])
        let result = try await makeProvider(transport: transport).transcribe(request)

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "안녕하세요")
        XCTAssertEqual(result.segments[0].startTime, 0.0)
        XCTAssertEqual(result.segments[0].endTime, 2.5)
        XCTAssertEqual(result.segments[0].speakerLabel, "speaker_1")
        XCTAssertEqual(result.segments[1].speakerLabel, "speaker_2")
        XCTAssertEqual(result.metadata.provider, .openAI)
        XCTAssertEqual(result.metadata.modelID, "gpt-4o-transcribe-diarize")
        XCTAssertEqual(result.metadata.completedAt, TestFixtures.fixedDate)
    }

    /// Diarization not coming back is a normal outcome, not a decoding failure.
    func testResponseWithoutSpeakersMapsToNilLabels() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요","start":0,"end":2}]}"#))
        ])
        let result = try await makeProvider(transport: transport).transcribe(request)

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertNil(result.segments[0].speakerLabel)
        XCTAssertEqual(result.segments[0].startTime, 0)
    }

    func testBlankSpeakerLabelBecomesNilRatherThanAnEmptyIdentity() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요","speaker":"  "}]}"#))
        ])
        let result = try await makeProvider(transport: transport).transcribe(request)
        XCTAssertNil(result.segments[0].speakerLabel)
    }

    func testResponseWithoutTimingsMapsToNilTimes() async throws {
        let transport = RecordingHTTPTransport([
            .status(200, body: Self.responseBody(#"{"segments":[{"text":"안녕하세요","speaker":"speaker_1"}]}"#))
        ])
        let result = try await makeProvider(transport: transport).transcribe(request)

        XCTAssertNil(result.segments[0].startTime)
        XCTAssertNil(result.segments[0].endTime)
        XCTAssertEqual(result.segments[0].speakerLabel, "speaker_1")
    }
}
