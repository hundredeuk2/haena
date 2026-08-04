import Foundation

// MARK: - Input

/// One transcript segment as handed to an extractor. Carries only what a model needs to read and
/// cite — deliberately not the full `TranscriptSegment`, so provider adapters never see domain
/// storage concerns.
struct TranscriptExcerpt: Equatable, Sendable {
    let segmentID: UUID
    let speakerLabel: String?
    let text: String
}

/// Everything an extractor is given about one meeting. Provider-neutral: no adapter type,
/// endpoint, or prompt appears here.
struct WorkStateExtractionInput: Equatable, Sendable {
    let meetingID: UUID
    let projectID: UUID
    let meetingTitle: String
    let occurredAt: Date
    let excerpts: [TranscriptExcerpt]
}

extension WorkStateExtractionInput {
    /// Builds the extractor input from a stored `Meeting`, resolving each segment's speaker to a
    /// display label where the meeting's participant list allows it.
    init(meeting: Meeting) {
        self.init(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            meetingTitle: meeting.title,
            occurredAt: meeting.occurredAt,
            excerpts: meeting.transcriptSegments.map { segment in
                TranscriptExcerpt(
                    segmentID: segment.id,
                    speakerLabel: Self.speakerLabel(for: segment, in: meeting),
                    text: segment.text
                )
            }
        )
    }

    private static func speakerLabel(for segment: TranscriptSegment, in meeting: Meeting) -> String? {
        guard let speakerID = segment.speakerID,
              let participant = meeting.participants.first(where: { $0.id == speakerID }) else {
            return nil
        }
        return participant.speakerLabel ?? participant.displayName
    }
}

// MARK: - Proposals

/// The model's claim about where an item came from.
///
/// `segmentID` stays a `String` rather than a `UUID` because it is echoed back by a model and is
/// therefore untrusted input: a malformed identifier and an unknown-but-well-formed identifier
/// are both just "this does not resolve to a segment of this meeting", and both are rejected in
/// one place by `WorkStateProposalMapper`.
struct ProposedEvidence: Equatable, Sendable {
    let segmentID: String
    let quote: String
}

struct ProposedDecision: Equatable, Sendable {
    let statement: String
    let rationale: String?
    let confidence: Double
    let evidence: ProposedEvidence
}

struct ProposedActionItem: Equatable, Sendable {
    let title: String
    let details: String?
    /// A name as it appeared in the transcript. Resolved to a `Participant` only on an
    /// unambiguous match — never guessed. See `WorkStateProposalMapper`.
    let assigneeName: String?
    /// Nil whenever the transcript did not state a date the adapter could parse unambiguously.
    let dueDate: Date?
    let confidence: Double
    let evidence: ProposedEvidence
}

struct ProposedOpenQuestion: Equatable, Sendable {
    let question: String
    let confidence: Double
    let evidence: ProposedEvidence
}

struct ProposedAgendaItem: Equatable, Sendable {
    let title: String
    let reason: String
    let confidence: Double
    let evidence: ProposedEvidence
}

/// One extractor run's raw output: still unvalidated, still not domain models. Turning this into
/// `Decision`/`ActionItem`/`OpenQuestion`/`AgendaItem` — with app-generated IDs and verified
/// evidence — is `WorkStateProposalMapper`'s job.
struct WorkStateExtractionResult: Equatable, Sendable {
    var decisions: [ProposedDecision]
    var actionItems: [ProposedActionItem]
    var openQuestions: [ProposedOpenQuestion]
    var nextAgendaItems: [ProposedAgendaItem]
    let metadata: ModelRunMetadata

    init(
        decisions: [ProposedDecision] = [],
        actionItems: [ProposedActionItem] = [],
        openQuestions: [ProposedOpenQuestion] = [],
        nextAgendaItems: [ProposedAgendaItem] = [],
        metadata: ModelRunMetadata
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.nextAgendaItems = nextAgendaItems
        self.metadata = metadata
    }
}

// MARK: - Extractor

/// The seam between HAE.NA's domain and whatever model produces work-state proposals.
///
/// Implementations may call a commercial API, run a local model, or compute results in process;
/// nothing about that choice may leak through this protocol. Only Foundation and HAE.NA domain
/// types appear in its signature — no request/response DTO, endpoint, or JSON Schema.
protocol WorkStateExtractor: Sendable {
    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult
}

/// Failure modes every provider must map onto, so callers can react (retry, ask for credentials,
/// show a message) without knowing which provider is configured.
///
/// Cases deliberately carry no provider-supplied free text: an error value must never be able to
/// smuggle an API key or a slice of the user's transcript into a log or an error message.
enum WorkStateExtractionError: Error, Equatable, Sendable {
    /// No API key was available. Never thrown with the key's value or length attached.
    case missingCredential
    case invalidConfiguration
    case unauthorized
    case rateLimited
    case serverError(statusCode: Int)
    case requestRejected(statusCode: Int)
    case timedOut
    case networkUnavailable
    /// The model declined to answer. The refusal text itself is intentionally dropped.
    case refused
    case emptyResponse
    case malformedResponse
}
