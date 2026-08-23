import Foundation

// MARK: - Request

/// Body of `POST /v1/responses`.
///
/// Structured Outputs live under `text.format` on this API (unlike Chat Completions, which nests
/// them under `response_format.json_schema`), with `name`, `strict`, and `schema` as siblings of
/// `type`.
struct OpenAIResponsesRequest: Encodable, Equatable, Sendable {
    let model: String
    let input: [InputMessage]
    let text: TextConfiguration

    struct InputMessage: Encodable, Equatable, Sendable {
        let role: String
        let content: String
    }

    struct TextConfiguration: Encodable, Equatable, Sendable {
        let format: Format
    }

    struct Format: Encodable, Equatable, Sendable {
        let type: String
        let name: String
        let strict: Bool
        let schema: JSONValue
    }
}

// MARK: - Response envelope

/// Only the parts of the response envelope this adapter reads. Unknown keys are ignored, so
/// additions on the provider's side do not break decoding.
struct OpenAIResponsesReply: Decodable, Sendable {
    let status: String?
    let output: [OutputItem]?
    let error: ResponseError?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case status
        case output
        case error
        case incompleteDetails = "incomplete_details"
    }

    struct ResponseError: Decodable, Sendable {
        let code: String?
        let type: String?
    }

    struct IncompleteDetails: Decodable, Sendable {
        let reason: String?
    }

    /// The `output` array interleaves item types — a reasoning item commonly precedes the
    /// assistant message — so the message must be located by `type`, not by position.
    struct OutputItem: Decodable, Sendable {
        let type: String?
        let content: [ContentPart]?
    }

    struct ContentPart: Decodable, Sendable {
        let type: String?
        let text: String?
        let refusal: String?
    }

    /// The model's JSON payload, or nil if the response carried no assistant text.
    var outputText: String? {
        let parts = output?
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] } ?? []
        let text = parts
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        return text.isEmpty ? nil : text
    }

    /// True when the model declined rather than answering. The refusal text is intentionally not
    /// surfaced — it is model-generated content, and no diagnostic value it carries is worth the
    /// risk of echoing transcript material into an error or a log.
    var isRefusal: Bool {
        output?
            .flatMap { $0.content ?? [] }
            .contains { $0.type == "refusal" || $0.refusal != nil } ?? false
    }
}

// MARK: - Structured payload

/// The JSON the model returns *inside* the assistant message, matching `OpenAIExtractionSchema`.
struct OpenAIExtractionPayload: Decodable, Sendable {
    let decisions: [DecisionDTO]
    let actionItems: [ActionItemDTO]
    let openQuestions: [OpenQuestionDTO]
    let nextAgendaItems: [AgendaItemDTO]
    let progressSignals: [ProgressSignalDTO]
    let openQuestionResolutionLinks: [OpenQuestionResolutionLinkDTO]
    let decisionDerivedActionItemLinks: [DecisionDerivedActionItemLinkDTO]
    let decisionChangeLinks: [DecisionChangeLinkDTO]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case nextAgendaItems = "next_agenda_items"
        case progressSignals = "progress_signals"
        case openQuestionResolutionLinks = "open_question_resolution_links"
        case decisionDerivedActionItemLinks = "decision_derived_action_item_links"
        case decisionChangeLinks = "decision_change_links"
    }

    init(from decoder: Decoder) throws {
        try Self.requireExactKeys(
            in: decoder,
            expected: CodingKeys.allCases.map(\.rawValue),
            description: "Extraction payload"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try container.decode([DecisionDTO].self, forKey: .decisions)
        actionItems = try container.decode([ActionItemDTO].self, forKey: .actionItems)
        openQuestions = try container.decode([OpenQuestionDTO].self, forKey: .openQuestions)
        nextAgendaItems = try container.decode([AgendaItemDTO].self, forKey: .nextAgendaItems)
        progressSignals = try container.decode([ProgressSignalDTO].self, forKey: .progressSignals)
        openQuestionResolutionLinks = try container.decode(
            [OpenQuestionResolutionLinkDTO].self,
            forKey: .openQuestionResolutionLinks
        )
        decisionDerivedActionItemLinks = try container.decode(
            [DecisionDerivedActionItemLinkDTO].self,
            forKey: .decisionDerivedActionItemLinks
        )
        decisionChangeLinks = try container.decode(
            [DecisionChangeLinkDTO].self,
            forKey: .decisionChangeLinks
        )
    }

    struct EvidenceDTO: Decodable, Sendable {
        let segmentID: String
        let quote: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case segmentID = "segment_id"
            case quote
        }

        init(from decoder: Decoder) throws {
            try OpenAIExtractionPayload.requireExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue),
                description: "Evidence"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            segmentID = try container.decode(String.self, forKey: .segmentID)
            quote = try container.decode(String.self, forKey: .quote)
        }
    }

    struct DecisionDTO: Decodable, Sendable {
        let providerKey: String
        let statement: String
        let rationale: String?
        let confidence: Double
        let evidence: EvidenceDTO

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case providerKey = "provider_key"
            case statement, rationale, confidence, evidence
        }

        init(from decoder: Decoder) throws {
            try OpenAIExtractionPayload.requireExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue),
                description: "Decision"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerKey = try container.decode(String.self, forKey: .providerKey)
            statement = try container.decode(String.self, forKey: .statement)
            rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
            confidence = try container.decode(Double.self, forKey: .confidence)
            evidence = try container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct ActionItemDTO: Decodable, Sendable {
        let providerKey: String
        let title: String
        let details: String?
        let assigneeBasis: AssigneeAttributionBasis
        let assigneeReference: String?
        let assigneeSpeaker: String?
        let dueDate: String?
        let confidence: Double
        let evidence: EvidenceDTO

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case providerKey = "provider_key"
            case title
            case details
            case assigneeBasis = "assignee_basis"
            case assigneeReference = "assignee_reference"
            case assigneeSpeaker = "assignee_speaker"
            case dueDate = "due_date"
            case confidence
            case evidence
        }

        init(from decoder: Decoder) throws {
            try OpenAIExtractionPayload.requireExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue),
                description: "Action item"
            )

            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerKey = try container.decode(String.self, forKey: .providerKey)
            title = try container.decode(String.self, forKey: .title)
            details = try container.decodeIfPresent(String.self, forKey: .details)
            let rawBasis = try container.decode(String.self, forKey: .assigneeBasis)
            guard let decodedBasis = AssigneeAttributionBasis(rawValue: rawBasis) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .assigneeBasis,
                    in: container,
                    debugDescription: "Unknown assignee attribution basis."
                )
            }
            assigneeBasis = decodedBasis
            assigneeReference = try container.decodeIfPresent(String.self, forKey: .assigneeReference)
            assigneeSpeaker = try container.decodeIfPresent(String.self, forKey: .assigneeSpeaker)
            dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
            confidence = try container.decode(Double.self, forKey: .confidence)
            evidence = try container.decode(EvidenceDTO.self, forKey: .evidence)

            guard Self.isValid(
                basis: assigneeBasis,
                reference: assigneeReference,
                speaker: assigneeSpeaker
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .assigneeBasis,
                    in: container,
                    debugDescription: "Assignee fields do not match the selected basis."
                )
            }
        }

        private static func isValid(
            basis: AssigneeAttributionBasis,
            reference: String?,
            speaker: String?
        ) -> Bool {
            let hasReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasSpeaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

            switch basis {
            case .explicitName:
                return hasReference && speaker == nil
            case .selfReference:
                return hasReference && hasSpeaker
            case .speakerCommitment:
                return (reference == nil || hasReference) && hasSpeaker
            case .teamOrRole:
                return hasReference && speaker == nil
            case .unspecified:
                return reference == nil && speaker == nil
            }
        }

    }

    struct OpenQuestionDTO: Decodable, Sendable {
        let providerKey: String
        let question: String
        let confidence: Double
        let evidence: EvidenceDTO

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case providerKey = "provider_key"
            case question, confidence, evidence
        }

        init(from decoder: Decoder) throws {
            try OpenAIExtractionPayload.requireExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue),
                description: "Open question"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerKey = try container.decode(String.self, forKey: .providerKey)
            question = try container.decode(String.self, forKey: .question)
            confidence = try container.decode(Double.self, forKey: .confidence)
            evidence = try container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct AgendaItemDTO: Decodable, Sendable {
        let providerKey: String
        let title: String
        let reason: String
        let confidence: Double
        let evidence: EvidenceDTO

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case providerKey = "provider_key"
            case title, reason, confidence, evidence
        }

        init(from decoder: Decoder) throws {
            try OpenAIExtractionPayload.requireExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue),
                description: "Agenda item"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerKey = try container.decode(String.self, forKey: .providerKey)
            title = try container.decode(String.self, forKey: .title)
            reason = try container.decode(String.self, forKey: .reason)
            confidence = try container.decode(Double.self, forKey: .confidence)
            evidence = try container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct ProgressSignalDTO: Decodable, Sendable {
        let kind: WorkStateProgressSignalKind?
        let targetType: WorkStateProgressSignalTargetType?
        let targetReference: String
        let evidence: EvidenceDTO?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind
            case targetType = "target_type"
            case targetReference = "target_reference"
            case evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let exactKeys = OpenAIExtractionPayload.hasExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue)
            )
            let rawKind = try? container.decode(String.self, forKey: .kind)
            kind = exactKeys ? rawKind.flatMap(WorkStateProgressSignalKind.init(rawValue:)) : nil
            let rawTargetType = try? container.decode(String.self, forKey: .targetType)
            targetType = exactKeys
                ? rawTargetType.flatMap(WorkStateProgressSignalTargetType.init(rawValue:))
                : nil
            targetReference = (try? container.decode(String.self, forKey: .targetReference)) ?? ""
            evidence = try? container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct DecisionChangeLinkDTO: Decodable, Sendable {
        let priorDecisionReference: String
        let decisionKey: String
        let evidence: EvidenceDTO?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case priorDecisionReference = "prior_decision_reference"
            case decisionKey = "decision_key"
            case evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            priorDecisionReference =
                (try? container.decode(String.self, forKey: .priorDecisionReference)) ?? ""
            decisionKey = (try? container.decode(String.self, forKey: .decisionKey)) ?? ""
            evidence = try? container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct OpenQuestionResolutionLinkDTO: Decodable, Sendable {
        let priorOpenQuestionReference: String
        let targetKind: WorkStateResolutionTargetKind?
        let targetKey: String
        let evidence: EvidenceDTO?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case priorOpenQuestionReference = "prior_open_question_ref"
            case targetKind = "target_kind"
            case targetKey = "target_key"
            case evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let exactKeys = OpenAIExtractionPayload.hasExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue)
            )
            priorOpenQuestionReference = (try? container.decode(String.self, forKey: .priorOpenQuestionReference)) ?? ""
            if exactKeys, let rawTargetKind = try? container.decode(String.self, forKey: .targetKind) {
                switch rawTargetKind {
                case "decision": targetKind = .decision
                case "action_item": targetKind = .actionItem
                case "agenda_item": targetKind = .agendaItem
                default: targetKind = nil
                }
            } else {
                targetKind = nil
            }
            targetKey = (try? container.decode(String.self, forKey: .targetKey)) ?? ""
            evidence = try? container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    struct DecisionDerivedActionItemLinkDTO: Decodable, Sendable {
        let incomingDecisionKey: String?
        let priorDecisionReference: String?
        let actionItemKey: String
        let evidence: EvidenceDTO?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case incomingDecisionKey = "incoming_decision_key"
            case priorDecisionReference = "prior_decision_ref"
            case actionItemKey = "action_item_key"
            case evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let exactKeys = OpenAIExtractionPayload.hasExactKeys(
                in: decoder,
                expected: CodingKeys.allCases.map(\.rawValue)
            )
            if exactKeys {
                incomingDecisionKey = try? container.decode(String.self, forKey: .incomingDecisionKey)
                priorDecisionReference = try? container.decode(String.self, forKey: .priorDecisionReference)
            } else {
                incomingDecisionKey = nil
                priorDecisionReference = nil
            }
            actionItemKey = (try? container.decode(String.self, forKey: .actionItemKey)) ?? ""
            evidence = try? container.decode(EvidenceDTO.self, forKey: .evidence)
        }
    }

    private static func requireExactKeys(
        in decoder: Decoder,
        expected: [String],
        description: String
    ) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(expected) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "\(description) keys do not match the strict provider contract."
                )
            )
        }
    }

    private static func hasExactKeys(in decoder: Decoder, expected: [String]) -> Bool {
        guard let raw = try? decoder.container(keyedBy: AnyCodingKey.self) else {
            return false
        }
        return Set(raw.allKeys.map(\.stringValue)) == Set(expected)
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
