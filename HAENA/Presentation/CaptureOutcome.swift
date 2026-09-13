import Foundation

/// Where a finished capture can send the user: the project and the meeting it just created.
struct CaptureDestination: Equatable, Sendable {
    let projectID: UUID
    let meetingID: UUID
}

/// How many results of each kind a meeting produced.
struct CaptureResultCounts: Equatable, Sendable {
    let decisions: Int
    let actionItems: Int
    let openQuestions: Int
    let agendaItems: Int

    var total: Int { decisions + actionItems + openQuestions + agendaItems }

    /// Every result attributed to the meeting, whatever state it is in.
    ///
    /// Right after a capture that is the same as "everything the model proposed", because nothing
    /// has been reviewed yet. It is written as the total rather than as the pending count so that
    /// re-running extraction over a meeting that already has approved results still reports what
    /// the meeting holds, instead of only what is new.
    init(summary: MeetingWorkStateSummary) {
        decisions = summary.decisions.totalCount
        actionItems = summary.actionItems.totalCount
        openQuestions = summary.openQuestions.totalCount
        agendaItems = summary.agendaItems.totalCount
    }

    init(decisions: Int, actionItems: Int, openQuestions: Int, agendaItems: Int) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.agendaItems = agendaItems
    }
}

/// What one finished capture produced, for the screen that reports it.
///
/// Held in memory for the length of one capture and never stored: no JSON field backs it, and no
/// domain model changed to make room for it. It exists so the three capture paths — pasted text,
/// an imported audio file, and a microphone recording — can end on the same screen and say the
/// same things, rather than each inventing its own success copy.
///
/// Only ever built for a capture that actually reached storage. A capture that failed before the
/// meeting was written has nothing to count and nowhere to send the user, and must keep the
/// existing error handling instead of borrowing this.
struct CaptureOutcome: Equatable, Sendable {
    let destination: CaptureDestination
    let meetingTitle: String

    /// Nil when the saved project could not be read back to count its results. The meeting is
    /// still saved and still reachable — this says the count is unknown, which is not the same
    /// claim as zero.
    let counts: CaptureResultCounts?

    /// Set when the meeting was saved but a later step was not. Never blocks: the screen still
    /// offers the meeting, because the meeting is really there.
    let notice: String?
    /// Separate from historical total counts (used by metrics/reanalysis). Only pending proposals
    /// may be labelled "awaiting review"; approved/processed results never enter this count.
    let pendingCounts: CaptureResultCounts?
    let preservation: CapturePreservation

    var projectID: UUID { destination.projectID }
    var meetingID: UUID { destination.meetingID }

    init(destination: CaptureDestination, meetingTitle: String, counts: CaptureResultCounts?, notice: String?,
         pendingCounts: CaptureResultCounts? = nil, preservation: CapturePreservation = .meetingOnly) {
        self.destination = destination
        self.meetingTitle = meetingTitle
        self.counts = counts
        self.notice = notice
        self.pendingCounts = pendingCounts
        self.preservation = preservation
    }

    /// Reads the saved project back and counts what the meeting actually holds.
    ///
    /// The counts come from storage rather than from the extraction report, because the report
    /// says what one run proposed and this screen answers "what does this meeting have now" — the
    /// two differ whenever a proposal was rejected on the way in, or a re-run replaced an earlier
    /// one. Attribution is `MeetingWorkStateSummary`'s, so these numbers cannot disagree with the
    /// screen the 결과 확인 button opens.
    static func make(
        for meeting: Meeting,
        notice: String?,
        repository: any ProjectRepository
    ) async -> CaptureOutcome {
        let destination = CaptureDestination(projectID: meeting.projectID, meetingID: meeting.id)
        let project = try? await repository.project(id: meeting.projectID)

        let summary = project.flatMap { project -> MeetingWorkStateSummary? in
            guard project.meetings.contains(where: { $0.id == meeting.id }) else { return nil }
            return MeetingWorkStateSummary(project: project, meetingID: meeting.id)
        }
        let counts = summary.map(CaptureResultCounts.init(summary:))
        let pending = summary.map {
            CaptureResultCounts(decisions: $0.decisions.needsReview.count,
                                actionItems: $0.actionItems.needsReview.count,
                                openQuestions: $0.openQuestions.needsReview.count,
                                agendaItems: $0.agendaItems.needsReview.count)
        }

        return CaptureOutcome(
            destination: destination,
            meetingTitle: meeting.title,
            counts: counts,
            notice: notice,
            pendingCounts: pending,
            preservation: CapturePreservation(saved: meeting)
        )
    }
}

/// One capture the user started: which path it came in on, and the instant they started waiting.
///
/// It lives next to `CaptureOutcome` because it keys off the same boundary. `CaptureOutcome` is
/// already the single definition of "a capture that actually reached storage", so a run that ends
/// with one succeeded and a run that ends without one did not — the three capture screens cannot
/// disagree about that, and now cannot disagree about how the wait was measured either.
///
/// Every recording method is non-throwing and every call it makes is to a non-throwing recorder,
/// so a run can be measured, or fail to be measured, without either outcome being visible to the
/// capture it describes. With no `BetaMetricsService` supplied it does nothing at all.
struct CaptureRun: Sendable {
    let id: UUID
    let source: BetaMetricCaptureSource
    private let startedAt: ContinuousClock.Instant
    private let metrics: BetaMetricsService?

    /// `startedAt` is read at construction, so the caller marks the start of the flow by building
    /// this at the point the user's wait begins — not at the point the result comes back.
    init(
        source: BetaMetricCaptureSource,
        metrics: BetaMetricsService?,
        id: UUID = UUID(),
        startedAt: ContinuousClock.Instant = .now
    ) {
        self.id = id
        self.source = source
        self.metrics = metrics
        self.startedAt = startedAt
    }

    /// Monotonic, and keeps counting while the machine sleeps — a transcription that ran for
    /// minutes cannot be reported as negative, or as zero, because the wall clock moved underneath
    /// it. Only this number is ever recorded: no audio, transcript, title, or error text.
    var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - startedAt
        let components = elapsed.components
        let milliseconds = components.seconds * 1_000
            + Int64(Double(components.attoseconds) / 1_000_000_000_000_000)
        return Int(clamping: max(0, milliseconds))
    }

    /// The terminal state of a capture that reached storage. Counts the meeting once, then the
    /// wait that produced it.
    func recordSuccess(_ outcome: CaptureOutcome) async {
        guard let metrics else {
            return
        }
        await metrics.recordMeetingProcessed(
            projectID: outcome.projectID,
            meetingID: outcome.meetingID,
            source: source,
            // Nil when the saved project could not be read back to count: unknown, not zero.
            resultCount: outcome.counts?.total
        )
        await metrics.recordProcessingDuration(
            runID: id,
            source: source,
            outcome: .succeeded,
            milliseconds: elapsedMilliseconds,
            meetingID: outcome.meetingID
        )
    }

    /// The terminal state of a capture that did not reach storage. No meeting is named because
    /// there is none: everything after the save is reported beside the meeting, not instead of it,
    /// so a run that got that far ends as a success even when extraction failed.
    func recordFailure() async {
        guard let metrics else {
            return
        }
        await metrics.recordProcessingDuration(
            runID: id,
            source: source,
            outcome: .failed,
            milliseconds: elapsedMilliseconds,
            meetingID: nil
        )
    }
}
