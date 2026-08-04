import XCTest
@testable import HAENA

/// Every test here drives `OpenAIWorkStateExtractor` through a stub transport. No test in this
/// file may reach api.openai.com — real-API checking is a separate, opt-in manual step.
final class OpenAIWorkStateExtractorTests: XCTestCase {
    private let fakeAPIKey = "test-api-key-THIS-MUST-NOT-LEAK"
    private let input = WorkStateExtractionInput(meeting: ExtractionFixtures.meeting())

    private func makeExtractor(
        transport: RecordingHTTPTransport,
        apiKey: String? = "test-api-key-THIS-MUST-NOT-LEAK",
        modelID: String = "test-model"
    ) -> OpenAIWorkStateExtractor {
        var configuration = OpenAIConfiguration(modelID: modelID)
        configuration.retryDelay = 0
        return OpenAIWorkStateExtractor(
            configuration: configuration,
            apiKeyProvider: { apiKey },
            transport: transport,
            now: { TestFixtures.fixedDate }
        )
    }

    private func extractionError(
        from transport: RecordingHTTPTransport,
        apiKey: String? = "test-api-key-THIS-MUST-NOT-LEAK",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> WorkStateExtractionError? {
        do {
            _ = try await makeExtractor(transport: transport, apiKey: apiKey).extract(from: input)
            XCTFail("expected the extraction to throw", file: file, line: line)
            return nil
        } catch {
            return error as? WorkStateExtractionError
        }
    }

    // MARK: - Response bodies

    private func envelope(withOutput output: [[String: Any]], status: String = "completed") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": "resp_test",
            "object": "response",
            "status": status,
            "output": output
        ])
    }

    private func successBody(payload: String = OpenAIWorkStateExtractorTests.validPayload) throws -> Data {
        try envelope(withOutput: [
            // A reasoning item precedes the message in real responses; the adapter must skip it
            // rather than assume the message is first.
            ["id": "rs_test", "type": "reasoning", "content": []],
            [
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": payload]]
            ]
        ])
    }

    private static let validPayload = """
    {
      "decisions": [
        {
          "statement": "2월 출시로 진행한다",
          "rationale": null,
          "confidence": 0.9,
          "evidence": {"segment_id": "00000000-0000-0000-0000-000000000004", "quote": "2월 출시로 가기로 했습니다"}
        }
      ],
      "action_items": [
        {
          "title": "지표 정의 초안 작성",
          "details": null,
          "assignee_name": null,
          "due_date": "2026-09-01",
          "confidence": 0.7,
          "evidence": {"segment_id": "00000000-0000-0000-0000-000000000004", "quote": "지표 정의는 아직"}
        }
      ],
      "open_questions": [
        {
          "question": "지표 정의는 누가 확정하는가?",
          "confidence": 0.6,
          "evidence": {"segment_id": "00000000-0000-0000-0000-000000000004", "quote": "지표 정의는 아직"}
        }
      ],
      "next_agenda_items": [
        {
          "title": "지표 정의 확정",
          "reason": "이번 회의에서 결론이 나지 않음",
          "confidence": 0.5,
          "evidence": {"segment_id": "00000000-0000-0000-0000-000000000004", "quote": "지표 정의는 아직"}
        }
      ]
    }
    """

    // MARK: - Success

    func testDecodesStructuredOutputIntoAllFourProposalKinds() async throws {
        let transport = RecordingHTTPTransport([.status(200, body: try successBody())])

        let result = try await makeExtractor(transport: transport).extract(from: input)

        XCTAssertEqual(result.decisions.count, 1)
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.openQuestions.count, 1)
        XCTAssertEqual(result.nextAgendaItems.count, 1)

        XCTAssertEqual(result.decisions[0].statement, "2월 출시로 진행한다")
        XCTAssertNil(result.decisions[0].rationale)
        XCTAssertEqual(result.decisions[0].confidence, 0.9)
        XCTAssertEqual(result.decisions[0].evidence.segmentID, TestFixtures.segmentID.uuidString)

        XCTAssertEqual(result.metadata.provider, .openAI)
        XCTAssertEqual(result.metadata.modelID, "test-model")
    }

    func testParsesAStatedDueDateAndRejectsAnUnparseableOne() async throws {
        let withDate = RecordingHTTPTransport([.status(200, body: try successBody())])
        let parsed = try await makeExtractor(transport: withDate).extract(from: input)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(parsed.actionItems[0].dueDate, utc.date(from: DateComponents(year: 2026, month: 9, day: 1)))

        let vaguePayload = Self.validPayload.replacingOccurrences(of: "\"2026-09-01\"", with: "\"다음 주\"")
        let withoutDate = RecordingHTTPTransport([.status(200, body: try successBody(payload: vaguePayload))])
        let unparsed = try await makeExtractor(transport: withoutDate).extract(from: input)
        XCTAssertNil(unparsed.actionItems[0].dueDate, "a phrase that is not a date must not become one")
    }

    func testEmptyArraysAreAValidResponse() async throws {
        let payload = """
        {"decisions": [], "action_items": [], "open_questions": [], "next_agenda_items": []}
        """
        let transport = RecordingHTTPTransport([.status(200, body: try successBody(payload: payload))])

        let result = try await makeExtractor(transport: transport).extract(from: input)

        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.nextAgendaItems.isEmpty)
    }

    // MARK: - Request construction

    func testSendsBearerAuthorizationAndAStrictJSONSchemaToTheResponsesEndpoint() async throws {
        let transport = RecordingHTTPTransport([.status(200, body: try successBody())])

        _ = try await makeExtractor(transport: transport).extract(from: input)

        let sentRequests = await transport.sentRequests
        let request = try XCTUnwrap(sentRequests.first)
        XCTAssertEqual(request.url, OpenAIConfiguration.defaultEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeAPIKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")

        let format = try XCTUnwrap((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, OpenAIExtractionSchema.name)
        XCTAssertEqual(format["strict"] as? Bool, true)

        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(required), ["decisions", "action_items", "open_questions", "next_agenda_items"])

        // The transcript is sent so the model can cite it, labelled with the segment id the
        // response has to echo back.
        let messages = try XCTUnwrap(json["input"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(userContent.contains(TestFixtures.segmentID.uuidString))
    }

    func testDefaultModelIsDefinedOnceAndOverriddenByEnvironment() {
        XCTAssertEqual(OpenAIConfiguration().modelID, OpenAIConfiguration.defaultModelID)
        XCTAssertEqual(OpenAIConfiguration.defaultModelID, "gpt-5.6")

        let overridden = OpenAIConfiguration.fromEnvironment(["OPENAI_MODEL": "gpt-5.6-mini"])
        XCTAssertEqual(overridden.modelID, "gpt-5.6-mini")

        let blank = OpenAIConfiguration.fromEnvironment(["OPENAI_MODEL": "   "])
        XCTAssertEqual(blank.modelID, OpenAIConfiguration.defaultModelID)
    }

    // MARK: - Credentials

    func testMissingAPIKeyFailsBeforeAnyRequestIsSent() async throws {
        let transport = RecordingHTTPTransport([.status(200, body: try successBody())])

        let error = await extractionError(from: transport, apiKey: nil)

        XCTAssertEqual(error, .missingCredential)
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 0, "no request may be sent without a credential")
    }

    func testBlankEnvironmentValueCountsAsNoCredential() {
        XCTAssertNil(OpenAIConfiguration.apiKey(from: [:]))
        XCTAssertNil(OpenAIConfiguration.apiKey(from: ["OPENAI_API_KEY": "   "]))
        XCTAssertEqual(OpenAIConfiguration.apiKey(from: ["OPENAI_API_KEY": " abc "]), "abc")
    }

    // MARK: - HTTP failures

    func testUnauthorizedResponseMapsToUnauthorized() async {
        let error = await extractionError(from: RecordingHTTPTransport([.status(401, body: Data())]))
        XCTAssertEqual(error, .unauthorized)
    }

    func testRateLimitIsRetriedThenReportedWithoutRetryingForever() async {
        let transport = RecordingHTTPTransport([.status(429, body: Data())])

        let error = await extractionError(from: transport)

        XCTAssertEqual(error, .rateLimited)
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 3, "one attempt plus the two configured retries, then stop")
    }

    func testRateLimitFollowedBySuccessResolvesWithoutSurfacingAnError() async throws {
        let transport = RecordingHTTPTransport(
            [.status(429, body: Data()), .status(200, body: try successBody())],
            repeatLast: false
        )

        let result = try await makeExtractor(transport: transport).extract(from: input)

        XCTAssertEqual(result.decisions.count, 1)
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 2)
    }

    func testServerErrorMapsToServerErrorWithItsStatusCode() async {
        let error = await extractionError(from: RecordingHTTPTransport([.status(503, body: Data())]))
        XCTAssertEqual(error, .serverError(statusCode: 503))
    }

    func testUnexpectedClientErrorMapsToRequestRejectedAndIsNotRetried() async {
        let transport = RecordingHTTPTransport([.status(400, body: Data())])

        let error = await extractionError(from: transport)

        XCTAssertEqual(error, .requestRejected(statusCode: 400))
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 1)
    }

    func testTimeoutMapsToTimedOutAndIsNotRetried() async {
        let transport = RecordingHTTPTransport([.failure(URLError(.timedOut))])

        let error = await extractionError(from: transport)

        XCTAssertEqual(error, .timedOut)
        let attempts = await transport.attemptCount
        XCTAssertEqual(attempts, 1, "a timeout may already have reached the provider — do not resend")
    }

    func testConnectionFailureMapsToNetworkUnavailable() async {
        let error = await extractionError(from: RecordingHTTPTransport([.failure(URLError(.notConnectedToInternet))]))
        XCTAssertEqual(error, .networkUnavailable)
    }

    // MARK: - Malformed and refused responses

    func testRefusalIsReportedAsRefusalRatherThanEmptyResult() async throws {
        let body = try envelope(withOutput: [[
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [["type": "refusal", "refusal": "I'm sorry, I cannot assist with that request."]]
        ]])

        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: body)]))

        XCTAssertEqual(error, .refused)
    }

    func testResponseWithNoAssistantTextMapsToEmptyResponse() async throws {
        let body = try envelope(withOutput: [["id": "rs_test", "type": "reasoning", "content": []]])

        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: body)]))

        XCTAssertEqual(error, .emptyResponse)
    }

    func testUnparseableEnvelopeMapsToMalformedResponse() async {
        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: Data("not json".utf8))]))
        XCTAssertEqual(error, .malformedResponse)
    }

    func testEmptyBodyMapsToMalformedResponse() async {
        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: Data())]))
        XCTAssertEqual(error, .malformedResponse)
    }

    func testPayloadThatDoesNotMatchTheSchemaMapsToMalformedResponse() async throws {
        let body = try successBody(payload: "{\"decisions\": \"not an array\"}")

        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: body)]))

        XCTAssertEqual(error, .malformedResponse)
    }

    // MARK: - Leak safety

    func testErrorsCarryNeitherTheAPIKeyNorTheTranscript() async throws {
        // A malformed payload that echoes both secrets back is the worst case for a decoding
        // error that wraps its input.
        let leakyPayload = "{\"decisions\": \"\(ExtractionFixtures.transcript) \(fakeAPIKey)\"}"
        let transport = RecordingHTTPTransport([.status(200, body: try successBody(payload: leakyPayload))])

        let error = await extractionError(from: transport)

        let described = String(describing: try XCTUnwrap(error))
        XCTAssertFalse(described.contains(fakeAPIKey), "an error must never carry the API key")
        XCTAssertFalse(described.contains("2월 출시"), "an error must never carry transcript content")
    }

    func testRefusalErrorDoesNotCarryTheModelsMessage() async throws {
        let secret = "REFUSAL-TEXT-SHOULD-NOT-PROPAGATE"
        let body = try envelope(withOutput: [[
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [["type": "refusal", "refusal": secret]]
        ]])

        let error = await extractionError(from: RecordingHTTPTransport([.status(200, body: body)]))

        XCTAssertFalse(String(describing: try XCTUnwrap(error)).contains(secret))
    }
}
