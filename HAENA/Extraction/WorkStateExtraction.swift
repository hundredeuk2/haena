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
    /// Approved prior state represented only by request-scoped opaque references. Provider
    /// adapters receive this view; the UUID lookup stays in `PriorWorkStateReferenceMap` and is
    /// passed only to the local mapper.
    let priorWorkStates: [PriorWorkStateProviderReference]
}

extension WorkStateExtractionInput {
    /// Builds provider input from the exact source labels stored beside transcript segments.
    /// Participant UUIDs, participant display names, and repository resolution never cross the
    /// extractor boundary.
    init(meeting: Meeting, priorWorkStates: [PriorWorkStateProviderReference] = []) {
        self.init(
            meetingID: meeting.id,
            projectID: meeting.projectID,
            meetingTitle: meeting.title,
            occurredAt: meeting.occurredAt,
            excerpts: meeting.transcriptSegments.map { segment in
                TranscriptExcerpt(
                    segmentID: segment.id,
                    speakerLabel: segment.sourceSpeakerLabel,
                    text: segment.text
                )
            },
            priorWorkStates: priorWorkStates
        )
    }

}

// MARK: - Approved prior-state context

/// The only prior-state statuses exposed to a provider. Every case is an approved state admitted
/// by `ApprovedWorkStatePolicy`; pending/rejected records never enter this context.
enum PriorWorkStateProviderState: String, Equatable, Sendable, CaseIterable {
    case confirmed
    case inProgress = "in_progress"
    case open
}

/// Minimal provider-visible context for matching an explicit continuity relationship.
///
/// No domain UUID, participant identity, old evidence quote, or storage detail belongs here.
struct PriorWorkStateProviderReference: Equatable, Sendable {
    let opaqueReference: String
    let kind: WorkStateKind
    let displayText: String
    let state: PriorWorkStateProviderState
}

/// One local-only allow-list entry. This type is never part of `WorkStateExtractionInput`.
struct PriorWorkStateDomainReference: Equatable, Sendable {
    let kind: WorkStateKind
    let domainID: UUID
}

/// Local half of the opaque-reference contract. The mapper resolves provider output through this
/// allow-list instead of accepting a model-supplied UUID.
struct PriorWorkStateReferenceMap: Equatable, Sendable {
    let domainReferencesByOpaqueReference: [String: PriorWorkStateDomainReference]

    static let empty = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: [:])

    func domainReference(for opaqueReference: String) -> PriorWorkStateDomainReference? {
        domainReferencesByOpaqueReference[opaqueReference]
    }
}

/// Both halves of one request-scoped prior-state context. Only `providerReferences` is copied into
/// extractor input; `referenceMap` stays inside the application boundary for local resolution.
struct PriorWorkStateContext: Equatable, Sendable {
    let providerReferences: [PriorWorkStateProviderReference]
    let referenceMap: PriorWorkStateReferenceMap

    static let empty = PriorWorkStateContext(
        providerReferences: [],
        referenceMap: .empty
    )

    /// Produces deterministic `prior_<kind>_<n>` references by sorting each kind by app UUID. The
    /// references are meaningful only for this request and reveal nothing about the UUIDs.
    init(snapshot: ApprovedWorkStateSnapshot) {
        var providerReferences: [PriorWorkStateProviderReference] = []
        var local: [String: PriorWorkStateDomainReference] = [:]

        func append(
            kind: WorkStateKind,
            prefix: String,
            values: [(id: UUID, text: String, state: PriorWorkStateProviderState)]
        ) {
            let sorted = values.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
            for (offset, value) in sorted.enumerated() {
                let opaqueReference = "prior_\(prefix)_\(offset + 1)"
                providerReferences.append(
                    PriorWorkStateProviderReference(
                        opaqueReference: opaqueReference,
                        kind: kind,
                        displayText: value.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        state: value.state
                    )
                )
                local[opaqueReference] = PriorWorkStateDomainReference(kind: kind, domainID: value.id)
            }
        }

        append(
            kind: .decision,
            prefix: "decision",
            values: snapshot.decisions
                .filter {
                    $0.projectID == snapshot.projectID && ApprovedWorkStatePolicy.isApproved($0)
                }
                .map { ($0.id, $0.statement, .confirmed) }
        )
        append(
            kind: .actionItem,
            prefix: "action",
            values: snapshot.actionItems
                .filter {
                    $0.projectID == snapshot.projectID && ApprovedWorkStatePolicy.isApproved($0)
                }
                .map {
                    ($0.id, $0.title, $0.status == .inProgress ? .inProgress : .confirmed)
                }
        )
        append(
            kind: .openQuestion,
            prefix: "question",
            values: snapshot.openQuestions
                .filter {
                    $0.projectID == snapshot.projectID && ApprovedWorkStatePolicy.isApproved($0)
                }
                .map { ($0.id, $0.question, .open) }
        )
        self.providerReferences = providerReferences
        self.referenceMap = PriorWorkStateReferenceMap(domainReferencesByOpaqueReference: local)
    }

    private init(
        providerReferences: [PriorWorkStateProviderReference],
        referenceMap: PriorWorkStateReferenceMap
    ) {
        self.providerReferences = providerReferences
        self.referenceMap = referenceMap
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
    let providerLocalKey: String
    let statement: String
    let rationale: String?
    let confidence: Double
    let evidence: ProposedEvidence
}

/// Provider-neutral assignee evidence carried by a proposed action item.
///
/// `reference` preserves only the assignee expression from the transcript (for example "민수님",
/// "제가", or "우리 팀"). `speakerLabel` is the transcript's opaque speaker label (for example
/// "B"), never a `Participant` UUID. Resolution to app-owned participants happens later in the
/// mapper after evidence validation.
struct ProposedAssigneeAttribution: Equatable, Sendable {
    let basis: AssigneeAttributionBasis
    let reference: String?
    let speakerLabel: String?
}

struct ProposedActionItem: Equatable, Sendable {
    let providerLocalKey: String
    let title: String
    let details: String?
    let assigneeAttribution: ProposedAssigneeAttribution
    /// Nil whenever the transcript did not state a date the adapter could parse unambiguously.
    let dueDate: Date?
    let confidence: Double
    let evidence: ProposedEvidence
}

struct ProposedOpenQuestion: Equatable, Sendable {
    let providerLocalKey: String
    let question: String
    let confidence: Double
    let evidence: ProposedEvidence
}

struct ProposedAgendaItem: Equatable, Sendable {
    let providerLocalKey: String
    let title: String
    let reason: String
    let confidence: Double
    let evidence: ProposedEvidence
}

// MARK: - Continuity signals

/// Raw sidecar claim. Optional enum/evidence fields preserve failure isolation for a hostile or
/// malformed provider response: the mapper can reject this signal finitely without discarding the
/// valid base work states decoded beside it.
/// Which namespace a progress signal's target reference belongs to.
///
/// A meeting that only reports on existing work — "that's done", "we pushed it", "it's stuck" —
/// extracts no new action item to hang the signal on, so the signal has to be able to name the
/// approved prior item directly. The two namespaces stay separate because a provider-local key and
/// a request-scoped prior reference mean different things and are resolved by different tables.
enum WorkStateProgressSignalTargetType: String, Codable, Equatable, Sendable, CaseIterable {
    case incomingActionItem = "incoming_action_item"
    case priorActionItem = "prior_action_item"
}

struct ProposedProgressSignal: Equatable, Sendable {
    let kind: WorkStateProgressSignalKind?
    /// Which namespace `targetReference` is read in. Optional so a malformed value rejects this one
    /// signal instead of silently defaulting to either namespace.
    let targetType: WorkStateProgressSignalTargetType?
    /// An incoming action item's provider-local key, or a supplied prior action item reference. The
    /// two are never interchangeable; `targetType` alone decides which one this is.
    let targetReference: String
    let evidence: ProposedEvidence?
}

/// "This decision revises that approved earlier one." Direct and typed, never inferred from titles.
struct ProposedDecisionChangeLink: Equatable, Sendable {
    let priorDecisionReference: String
    let decisionKey: String
    let evidence: ProposedEvidence?
}

struct ProposedOpenQuestionResolutionLink: Equatable, Sendable {
    let priorOpenQuestionReference: String
    let targetKind: WorkStateResolutionTargetKind?
    let targetProviderLocalKey: String
    let evidence: ProposedEvidence?
}

struct ProposedDecisionDerivedActionItemLink: Equatable, Sendable {
    /// Exactly one source form must be non-nil. Keeping both raw fields lets the local mapper reject
    /// an ambiguous provider claim rather than allowing a decoder to choose one silently.
    let sourceDecisionKey: String?
    let priorDecisionReference: String?
    let actionItemKey: String
    let evidence: ProposedEvidence?
}

/// One extractor run's raw output: still unvalidated, still not domain models. Turning this into
/// `Decision`/`ActionItem`/`OpenQuestion`/`AgendaItem` — with app-generated IDs and verified
/// evidence — is `WorkStateProposalMapper`'s job.
struct WorkStateExtractionResult: Equatable, Sendable {
    var decisions: [ProposedDecision]
    var actionItems: [ProposedActionItem]
    var openQuestions: [ProposedOpenQuestion]
    var nextAgendaItems: [ProposedAgendaItem]
    var progressSignals: [ProposedProgressSignal]
    var openQuestionResolutionLinks: [ProposedOpenQuestionResolutionLink]
    var decisionDerivedActionItemLinks: [ProposedDecisionDerivedActionItemLink]
    var decisionChangeLinks: [ProposedDecisionChangeLink]
    let metadata: ModelRunMetadata

    init(
        decisions: [ProposedDecision] = [],
        actionItems: [ProposedActionItem] = [],
        openQuestions: [ProposedOpenQuestion] = [],
        nextAgendaItems: [ProposedAgendaItem] = [],
        progressSignals: [ProposedProgressSignal] = [],
        openQuestionResolutionLinks: [ProposedOpenQuestionResolutionLink] = [],
        decisionDerivedActionItemLinks: [ProposedDecisionDerivedActionItemLink] = [],
        decisionChangeLinks: [ProposedDecisionChangeLink] = [],
        metadata: ModelRunMetadata
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.nextAgendaItems = nextAgendaItems
        self.progressSignals = progressSignals
        self.openQuestionResolutionLinks = openQuestionResolutionLinks
        self.decisionDerivedActionItemLinks = decisionDerivedActionItemLinks
        self.decisionChangeLinks = decisionChangeLinks
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
