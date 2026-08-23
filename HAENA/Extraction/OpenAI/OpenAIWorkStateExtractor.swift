import Foundation

/// `WorkStateExtractor` backed by the OpenAI Responses API with Structured Outputs.
///
/// OpenAI is HAE.NA's first provider, not its only possible one: everything OpenAI-specific — the
/// endpoint, the request/response DTOs, the JSON Schema, the model ID — stops at this file. The
/// domain sees only `WorkStateExtractionInput`, `WorkStateExtractionResult`, and
/// `WorkStateExtractionError`, so a second commercial API, a local model, or an SKT model can be
/// added as a sibling type without the rest of the app knowing.
struct OpenAIWorkStateExtractor: WorkStateExtractor {
    private let configuration: OpenAIConfiguration
    private let apiKeyProvider: @Sendable () -> String?
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    init(
        configuration: OpenAIConfiguration = .fromEnvironment(),
        apiKeyProvider: @escaping @Sendable () -> String? = { OpenAICredentialResolver.shared.apiKey() },
        transport: (any HTTPTransport)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport ?? URLSessionHTTPTransport(requestTimeout: configuration.requestTimeout)
        self.now = now
    }

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        // Resolved per call, not at init: the app must launch, and meetings must keep saving,
        // when no key is configured.
        guard let apiKey = apiKeyProvider() else {
            throw WorkStateExtractionError.missingCredential
        }

        let request = try makeRequest(for: input, apiKey: apiKey)
        let (data, response) = try await send(request)
        try Self.validate(statusCode: response.statusCode)

        let reply: OpenAIResponsesReply
        do {
            reply = try JSONDecoder().decode(OpenAIResponsesReply.self, from: data)
        } catch {
            // The underlying error is dropped rather than wrapped: a decoding failure's
            // description can quote the payload it choked on, which is the user's meeting.
            throw WorkStateExtractionError.malformedResponse
        }

        if reply.isRefusal {
            throw WorkStateExtractionError.refused
        }
        if reply.error != nil {
            throw WorkStateExtractionError.malformedResponse
        }
        guard let outputText = reply.outputText else {
            throw WorkStateExtractionError.emptyResponse
        }

        let payload: OpenAIExtractionPayload
        do {
            payload = try JSONDecoder().decode(OpenAIExtractionPayload.self, from: Data(outputText.utf8))
        } catch {
            throw WorkStateExtractionError.malformedResponse
        }

        return Self.map(
            payload,
            metadata: ModelRunMetadata(
                provider: .openAI,
                modelID: configuration.modelID,
                completedAt: now()
            )
        )
    }

    // MARK: - Request

    private func makeRequest(for input: WorkStateExtractionInput, apiKey: String) throws -> URLRequest {
        let body = OpenAIResponsesRequest(
            model: configuration.modelID,
            input: [
                .init(role: "system", content: OpenAIExtractionSchema.instructions),
                .init(role: "user", content: Self.userContent(for: input))
            ],
            text: .init(
                format: .init(
                    type: "json_schema",
                    name: OpenAIExtractionSchema.name,
                    strict: true,
                    schema: OpenAIExtractionSchema.schema()
                )
            )
        )

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw WorkStateExtractionError.invalidConfiguration
        }

        return request
    }

    /// Segment ids are labelled inline so the model can cite them, and so a returned id can be
    /// checked against this meeting's segments rather than trusted.
    private static func userContent(for input: WorkStateExtractionInput) -> String {
        var lines = ["Meeting title: \(input.meetingTitle)"]
        if !input.priorWorkStates.isEmpty {
            lines.append("")
            lines.append("Approved prior work state (request-scoped opaque references only):")
            lines.append(encodedPriorContext(input.priorWorkStates))
        }
        lines.append("")
        lines.append("Transcript segments:")
        for excerpt in input.excerpts {
            lines.append("")
            lines.append("[segment_id: \(excerpt.segmentID.uuidString)]")
            if let speaker = excerpt.speakerLabel {
                lines.append("[speaker: \(speaker)]")
            }
            lines.append(excerpt.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Encodes only the provider-safe half of the prior-state map. Project, meeting, participant,
    /// and work-state UUIDs are structurally absent from `PriorWorkStateProviderReference`, so this
    /// boundary cannot accidentally serialize them while adding future request fields.
    private static func encodedPriorContext(_ references: [PriorWorkStateProviderReference]) -> String {
        let objects = references.map {
            [
                "opaque_reference": $0.opaqueReference,
                "kind": $0.kind.rawValue,
                "display_text": $0.displayText,
                "state": $0.state.rawValue,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    // MARK: - Sending

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let result: (data: Data, response: HTTPURLResponse)
            do {
                let (data, response) = try await transport.send(request)
                result = (data, response)
            } catch let error as WorkStateExtractionError {
                throw error
            } catch let error as URLError {
                throw Self.mapped(error)
            } catch {
                throw WorkStateExtractionError.networkUnavailable
            }

            // Retried only where a retry is safe and likely to help: the request was never
            // accepted, so re-sending cannot duplicate work on the provider's side. Timeouts and
            // 4xx responses are not retried, and the attempt count is bounded.
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
            throw WorkStateExtractionError.unauthorized
        case 408:
            throw WorkStateExtractionError.timedOut
        case 429:
            throw WorkStateExtractionError.rateLimited
        case 500...599:
            throw WorkStateExtractionError.serverError(statusCode: statusCode)
        default:
            throw WorkStateExtractionError.requestRejected(statusCode: statusCode)
        }
    }

    private static func mapped(_ error: URLError) -> WorkStateExtractionError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .networkUnavailable
        default:
            return .networkUnavailable
        }
    }

    // MARK: - Mapping

    /// DTO to provider-neutral proposals. No validation happens here beyond parsing: whether a
    /// quote is real, a segment exists, or a confidence is in range is decided once, in
    /// `WorkStateProposalMapper`, against the stored transcript.
    private static func map(
        _ payload: OpenAIExtractionPayload,
        metadata: ModelRunMetadata
    ) -> WorkStateExtractionResult {
        WorkStateExtractionResult(
            decisions: payload.decisions.map {
                ProposedDecision(
                    providerLocalKey: $0.providerKey,
                    statement: $0.statement,
                    rationale: $0.rationale,
                    confidence: $0.confidence,
                    evidence: mapped($0.evidence)
                )
            },
            actionItems: payload.actionItems.map {
                ProposedActionItem(
                    providerLocalKey: $0.providerKey,
                    title: $0.title,
                    details: $0.details,
                    assigneeAttribution: ProposedAssigneeAttribution(
                        basis: $0.assigneeBasis,
                        reference: $0.assigneeReference,
                        speakerLabel: $0.assigneeSpeaker
                    ),
                    dueDate: parseDueDate($0.dueDate),
                    confidence: $0.confidence,
                    evidence: mapped($0.evidence)
                )
            },
            openQuestions: payload.openQuestions.map {
                ProposedOpenQuestion(
                    providerLocalKey: $0.providerKey,
                    question: $0.question,
                    confidence: $0.confidence,
                    evidence: mapped($0.evidence)
                )
            },
            nextAgendaItems: payload.nextAgendaItems.map {
                ProposedAgendaItem(
                    providerLocalKey: $0.providerKey,
                    title: $0.title,
                    reason: $0.reason,
                    confidence: $0.confidence,
                    evidence: mapped($0.evidence)
                )
            },
            progressSignals: payload.progressSignals.map {
                ProposedProgressSignal(
                    kind: $0.kind,
                    targetType: $0.targetType,
                    targetReference: $0.targetReference,
                    evidence: mapped($0.evidence)
                )
            },
            openQuestionResolutionLinks: payload.openQuestionResolutionLinks.map {
                ProposedOpenQuestionResolutionLink(
                    priorOpenQuestionReference: $0.priorOpenQuestionReference,
                    targetKind: $0.targetKind,
                    targetProviderLocalKey: $0.targetKey,
                    evidence: mapped($0.evidence)
                )
            },
            decisionDerivedActionItemLinks: payload.decisionDerivedActionItemLinks.map {
                ProposedDecisionDerivedActionItemLink(
                    sourceDecisionKey: $0.incomingDecisionKey,
                    priorDecisionReference: $0.priorDecisionReference,
                    actionItemKey: $0.actionItemKey,
                    evidence: mapped($0.evidence)
                )
            },
            decisionChangeLinks: payload.decisionChangeLinks.map {
                ProposedDecisionChangeLink(
                    priorDecisionReference: $0.priorDecisionReference,
                    decisionKey: $0.decisionKey,
                    evidence: mapped($0.evidence)
                )
            },
            metadata: metadata
        )
    }

    private static func mapped(_ evidence: OpenAIExtractionPayload.EvidenceDTO) -> ProposedEvidence {
        ProposedEvidence(segmentID: evidence.segmentID, quote: evidence.quote)
    }

    private static func mapped(_ evidence: OpenAIExtractionPayload.EvidenceDTO?) -> ProposedEvidence? {
        evidence.map { mapped($0) }
    }

    /// Accepts only a complete `yyyy-MM-dd` date in UTC. Anything else — a relative phrase, a
    /// month without a day, an unparseable string — becomes nil, because a task with no due date
    /// is accurate while a task with an invented one is not.
    private static func parseDueDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else {
            return nil
        }
        calendar.timeZone = utc

        let components = value.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]), components[0].count == 4,
              let month = Int(components[1]), components[1].count == 2,
              let day = Int(components[2]), components[2].count == 2 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
