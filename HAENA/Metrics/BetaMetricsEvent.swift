import Foundation

/// What a single beta measurement fact is about.
///
/// The list is closed and small on purpose. A beta measurement answers a fixed set of questions —
/// did the user get a meeting through the app, did they judge what it proposed, did they have to
/// correct it, and how long did they wait — and a type that could describe anything else would
/// eventually be used to describe the meeting itself.
enum BetaMetricEventType: String, Codable, Equatable, Sendable, CaseIterable {
    case meetingProcessed
    case proposalReviewed
    case proposalModified
    case processingDuration
}

/// A person's verdict on one AI proposal, reduced to the only distinction the beta measures.
///
/// `WorkStateReviewService` has richer outcomes per domain type (a Decision is confirmed, a
/// question is resolved, an agenda item is accepted). All of them collapse to the same two facts
/// here: the user kept it, or the user threw it away. Keeping the richer vocabulary would make the
/// approval rate depend on which domain type happened to be reviewed.
enum BetaMetricVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case approved
    case excluded
}

/// Which of the four proposal types a review fact is about.
///
/// Deliberately mirrors `WorkStateProposal.Kind` rather than referencing it: the stored schema must
/// not shift underneath an existing `beta-metrics.json` if the presentation enum is ever renamed or
/// extended. The `init(_:)` below is the single place the two vocabularies are mapped.
enum BetaMetricProposalKind: String, Codable, Equatable, Sendable, CaseIterable {
    case decision
    case actionItem
    case openQuestion
    case agendaItem

    init(_ kind: WorkStateProposal.Kind) {
        switch kind {
        case .decision: self = .decision
        case .actionItem: self = .actionItem
        case .openQuestion: self = .openQuestion
        case .agendaItem: self = .agendaItem
        }
    }
}

/// Which field a person had to correct before accepting a proposal.
///
/// Only the two fields the extractor actually guesses at. The corrected *value* is never recorded —
/// an assignee name and a due date are both personal facts, and the metric only needs to know that
/// the model got the field wrong often enough to matter.
enum BetaMetricFieldCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case assignee
    case dueDate
}

/// How the meeting entered the app.
///
/// Coarser than `MeetingSourceType` because the beta question is about the user's effort, not the
/// container format: dropping in an `.m4a` and dropping in an `.mp4` are the same act.
enum BetaMetricCaptureSource: String, Codable, Equatable, Sendable, CaseIterable {
    case pastedText
    case importedAudio
    case recordedAudio

    init(_ sourceType: MeetingSourceType) {
        switch sourceType {
        case .pastedText: self = .pastedText
        case .audioFile, .videoFile: self = .importedAudio
        case .microphone: self = .recordedAudio
        }
    }
}

/// Whether a timed run finished or gave up.
///
/// Recorded alongside every duration so a median can later be read as "how long users wait", and
/// separately as "how long they wait before being told it did not work" — without needing a second
/// event type or a re-measured beta.
enum BetaMetricOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    case succeeded
    case failed
}

/// One privacy-minimal beta measurement fact.
///
/// The type has exactly one `String` stored property — `deduplicationKey` — and that string is
/// assembled only from an event-type prefix and UUIDs. Everything else is a UUID, an enum case, a
/// number, or a date. This is a structural guarantee rather than a convention: there is no field a
/// meeting title, participant name, transcript line, evidence quote, notification body, or API key
/// could be written into, so no future caller can leak one by accident. `BetaMetricsPrivacyTests`
/// asserts the shape by reflection so that adding a `String` field breaks the build's test run.
///
/// Note what the identifiers are *for*. `projectID` and `meetingID` are stored so a fact can be
/// discarded when its source is deleted and so double counting can be detected — never so a metric
/// can be joined back to content for reporting. Nothing here leaves the machine.
struct BetaMetricEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Stable across retries of the same real-world act. See `BetaMetricsService` for how each
    /// event type's key is built and why one is chosen over another.
    let deduplicationKey: String
    let type: BetaMetricEventType
    let occurredAt: Date
    let projectID: UUID?
    let meetingID: UUID?
    let proposalID: UUID?
    let proposalKind: BetaMetricProposalKind?
    let verdict: BetaMetricVerdict?
    let fieldCategory: BetaMetricFieldCategory?
    let captureSource: BetaMetricCaptureSource?
    let outcome: BetaMetricOutcome?
    let durationMilliseconds: Int?
    let resultCount: Int?

    init(
        id: UUID,
        deduplicationKey: String,
        type: BetaMetricEventType,
        occurredAt: Date,
        projectID: UUID? = nil,
        meetingID: UUID? = nil,
        proposalID: UUID? = nil,
        proposalKind: BetaMetricProposalKind? = nil,
        verdict: BetaMetricVerdict? = nil,
        fieldCategory: BetaMetricFieldCategory? = nil,
        captureSource: BetaMetricCaptureSource? = nil,
        outcome: BetaMetricOutcome? = nil,
        durationMilliseconds: Int? = nil,
        resultCount: Int? = nil
    ) {
        self.id = id
        self.deduplicationKey = deduplicationKey
        self.type = type
        self.occurredAt = occurredAt
        self.projectID = projectID
        self.meetingID = meetingID
        self.proposalID = proposalID
        self.proposalKind = proposalKind
        self.verdict = verdict
        self.fieldCategory = fieldCategory
        self.captureSource = captureSource
        self.outcome = outcome
        self.durationMilliseconds = durationMilliseconds
        self.resultCount = resultCount
    }
}

/// The versioned envelope written to `beta-metrics.json`.
///
/// `measurementStartedAt` is the only thing that makes the stored events mean anything: a rate is
/// a claim about a period, and without a start the same file would report "since some time in the
/// past". It is also the erasure boundary — `reset(at:)` moves it forward and drops every event, so
/// a user who wants their measurement to start over is not left with numbers derived from data they
/// asked to be rid of.
struct BetaMetricsStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var measurementStartedAt: Date
    var events: [BetaMetricEvent]

    init(
        schemaVersion: Int = BetaMetricsStoreFile.currentSchemaVersion,
        measurementStartedAt: Date,
        events: [BetaMetricEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.measurementStartedAt = measurementStartedAt
        self.events = events
    }
}
