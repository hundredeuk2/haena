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

    var projectID: UUID { destination.projectID }
    var meetingID: UUID { destination.meetingID }

    init(destination: CaptureDestination, meetingTitle: String, counts: CaptureResultCounts?, notice: String?) {
        self.destination = destination
        self.meetingTitle = meetingTitle
        self.counts = counts
        self.notice = notice
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

        let counts = project.map {
            CaptureResultCounts(summary: MeetingWorkStateSummary(project: $0, meetingID: meeting.id))
        }

        return CaptureOutcome(
            destination: destination,
            meetingTitle: meeting.title,
            counts: counts,
            notice: notice
        )
    }
}
