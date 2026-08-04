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

    enum CodingKeys: String, CodingKey {
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case nextAgendaItems = "next_agenda_items"
    }

    struct EvidenceDTO: Decodable, Sendable {
        let segmentID: String
        let quote: String

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case quote
        }
    }

    struct DecisionDTO: Decodable, Sendable {
        let statement: String
        let rationale: String?
        let confidence: Double
        let evidence: EvidenceDTO
    }

    struct ActionItemDTO: Decodable, Sendable {
        let title: String
        let details: String?
        let assigneeName: String?
        let dueDate: String?
        let confidence: Double
        let evidence: EvidenceDTO

        enum CodingKeys: String, CodingKey {
            case title
            case details
            case assigneeName = "assignee_name"
            case dueDate = "due_date"
            case confidence
            case evidence
        }
    }

    struct OpenQuestionDTO: Decodable, Sendable {
        let question: String
        let confidence: Double
        let evidence: EvidenceDTO
    }

    struct AgendaItemDTO: Decodable, Sendable {
        let title: String
        let reason: String
        let confidence: Double
        let evidence: EvidenceDTO
    }
}
