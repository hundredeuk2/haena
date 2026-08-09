import Foundation

/// One of the four kinds of result a meeting produces, split by how far each result has been
/// through review.
///
/// The three buckets are mutually exclusive and, together, exhaustive: every stored result that
/// belongs to the meeting lands in exactly one of them. That is deliberate — a bucket set built
/// from three positive predicates would silently drop anything none of them happened to match,
/// and a dropped result is indistinguishable on screen from one that was never extracted.
struct MeetingResultArea<Item: Identifiable & Equatable & Sendable>: Equatable, Sendable
where Item.ID == UUID {
    /// AI proposals from this meeting that nobody has ruled on yet.
    ///
    /// Carried as `WorkStateProposal` — the shape the project-wide review screen already renders —
    /// so the two screens cannot disagree about what a proposal is, what it shows, or what may be
    /// done with it.
    let needsReview: [WorkStateProposal]

    /// Results that are currently part of the project's state.
    let reviewed: [Item]

    /// Results that have been closed out: rejected, superseded, completed, cancelled, resolved or
    /// dismissed. Kept rather than deleted — a suggestion that was turned down is part of what the
    /// meeting produced — but held apart from the live list so it does not compete with it.
    let processed: [Item]

    init(needsReview: [WorkStateProposal] = [], reviewed: [Item] = [], processed: [Item] = []) {
        self.needsReview = needsReview
        self.reviewed = reviewed
        self.processed = processed
    }

    /// What the section header counts: everything still live. Processed results are counted
    /// separately on their own row, because folding them in would make a meeting whose every
    /// suggestion was rejected look identical to one that produced nothing.
    var activeCount: Int { needsReview.count + reviewed.count }

    var isEmpty: Bool { activeCount == 0 }

    var totalCount: Int { activeCount + processed.count }
}

/// A read-only answer to "what did *this meeting* turn into", derived entirely from an existing
/// `Project` value: nothing here is stored, no JSON field backs it, and no model is called.
///
/// The meeting results screen owns no filtering or ordering rules of its own — this type is the
/// single place either question is answered for a meeting. Every predicate it uses is one the app
/// already agrees on elsewhere (`PendingAIProposalPolicy`, `WorkStateInbox`,
/// `ProjectStatusSummary.isOrderedByDueDate`), so a result cannot appear as settled here while the
/// review screen still treats it as a proposal.
struct MeetingWorkStateSummary: Equatable, Sendable {
    let meetingID: UUID

    let decisions: MeetingResultArea<Decision>
    let actionItems: MeetingResultArea<ActionItem>
    let openQuestions: MeetingResultArea<OpenQuestion>
    let agendaItems: MeetingResultArea<AgendaItem>

    init(project: Project, meetingID: UUID) {
        self.meetingID = meetingID

        // Narrowing the project first, then running the app's existing project-wide selectors over
        // the narrowed value, is what keeps this type from re-deriving any of them.
        let scoped = Self.scoped(project, toMeeting: meetingID)
        let proposals = WorkStateInbox.pendingProposals(in: scoped)

        decisions = MeetingResultArea(
            needsReview: proposals.filter { $0.kind == .decision },
            reviewed: scoped.decisions
                .filter { Self.isReviewed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore),
            processed: scoped.decisions
                .filter { Self.isProcessed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore)
        )

        actionItems = MeetingResultArea(
            needsReview: proposals.filter { $0.kind == .actionItem },
            // The one area ordered by something other than recency: work is read to answer "what
            // do I have to do next", which is a question about deadlines. Same comparator the
            // project status screen uses, so the two lists never disagree.
            reviewed: scoped.actionItems
                .filter { Self.isReviewed($0) }
                .sorted(by: ProjectStatusSummary.isOrderedByDueDate),
            processed: scoped.actionItems
                .filter { Self.isProcessed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore)
        )

        openQuestions = MeetingResultArea(
            needsReview: proposals.filter { $0.kind == .openQuestion },
            reviewed: scoped.openQuestions
                .filter { Self.isReviewed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore),
            processed: scoped.openQuestions
                .filter { Self.isProcessed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore)
        )

        agendaItems = MeetingResultArea(
            needsReview: proposals.filter { $0.kind == .agendaItem },
            reviewed: scoped.nextAgenda
                .filter { Self.isReviewed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore),
            processed: scoped.nextAgenda
                .filter { Self.isProcessed($0) }
                .sorted(by: WorkStateInbox.isOrderedBefore)
        )
    }

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && agendaItems.isEmpty
    }

    // MARK: - Meeting attribution

    /// The same project, holding only the results this meeting produced.
    ///
    /// Attribution uses each model's own direct link — `meetingID`, and `sourceMeetingID` for an
    /// agenda item — never `EvidenceReference.meetingID`. Evidence points at the transcript a quote
    /// came from and is the right thing to show beside a result, but it is absent on anything a
    /// person typed in, so using it to decide ownership would attach hand-entered work to whichever
    /// meeting happened to be quoted. An agenda item with no `sourceMeetingID` belongs to no
    /// meeting and is left out of every meeting's results rather than assigned to one.
    ///
    /// `projectID` is re-checked as well. Within one loaded `Project` it is always redundant; it is
    /// here so a record that somehow carries a foreign project's id cannot be rendered as this
    /// project's meeting output.
    private static func scoped(_ project: Project, toMeeting meetingID: UUID) -> Project {
        var scoped = project
        scoped.decisions = project.decisions.filter {
            $0.projectID == project.id && $0.meetingID == meetingID
        }
        scoped.actionItems = project.actionItems.filter {
            $0.projectID == project.id && $0.meetingID == meetingID
        }
        scoped.openQuestions = project.openQuestions.filter {
            $0.projectID == project.id && $0.meetingID == meetingID
        }
        scoped.nextAgenda = project.nextAgenda.filter {
            $0.projectID == project.id && $0.sourceMeetingID == meetingID
        }
        return scoped
    }

    // MARK: - Status classification

    /// Closed out by a person: turned down, replaced, finished, or cancelled.
    ///
    /// This is the only predicate this type introduces. It is expressed as terminal *statuses*
    /// rather than as "not one of the live ones", so adding a status to a domain enum surfaces as a
    /// compile-time switch rather than as a record silently changing category.
    static func isProcessed(_ decision: Decision) -> Bool {
        switch decision.status {
        case .rejected, .superseded: return true
        case .proposed, .confirmed: return false
        }
    }

    static func isProcessed(_ actionItem: ActionItem) -> Bool {
        switch actionItem.status {
        case .completed, .cancelled: return true
        case .proposed, .confirmed, .inProgress: return false
        }
    }

    static func isProcessed(_ question: OpenQuestion) -> Bool {
        switch question.status {
        case .resolved, .dismissed: return true
        case .open: return false
        }
    }

    static func isProcessed(_ agendaItem: AgendaItem) -> Bool {
        switch agendaItem.status {
        case .resolved, .dismissed: return true
        case .pending: return false
        }
    }

    /// Live, and not waiting on anyone.
    ///
    /// Defined as the remainder rather than as its own list of statuses, which is what makes the
    /// three buckets exhaustive. For everything a model produced this is exactly
    /// `WorkStateInbox.confirmedDecisions` / `activeActionItems` / `reviewedOpenQuestions` /
    /// `reviewedAgendaItems` narrowed to the meeting — `MeetingWorkStateSummaryTests` asserts that
    /// equality directly. The remainder form additionally covers the one record those selectors do
    /// not name: a result someone typed in by hand, which has no evidence and so is not a pending
    /// proposal, and no terminal status either. It belongs to its author, not to the last model
    /// run, and showing it as live is the only honest place to put it.
    static func isReviewed(_ decision: Decision) -> Bool {
        !PendingAIProposalPolicy.isPending(decision) && !isProcessed(decision)
    }

    static func isReviewed(_ actionItem: ActionItem) -> Bool {
        !PendingAIProposalPolicy.isPending(actionItem) && !isProcessed(actionItem)
    }

    static func isReviewed(_ question: OpenQuestion) -> Bool {
        !PendingAIProposalPolicy.isPending(question) && !isProcessed(question)
    }

    static func isReviewed(_ agendaItem: AgendaItem) -> Bool {
        !PendingAIProposalPolicy.isPending(agendaItem) && !isProcessed(agendaItem)
    }

    // MARK: - Evidence

    /// Where in the recording a quote came from, as `mm:ss`, or nil when that cannot be answered
    /// truthfully — no evidence, evidence pointing at a different meeting, a segment that no longer
    /// exists, or a transcript with no timing at all (pasted text). A quote is a trust feature, and
    /// a fabricated timestamp beside one would undo exactly the trust it is there to earn.
    static func evidenceTimestamp(_ evidence: EvidenceReference?, in meeting: Meeting) -> String? {
        guard let evidence, evidence.meetingID == meeting.id else {
            return nil
        }
        guard let segment = meeting.transcriptSegments.first(where: {
            $0.id == evidence.transcriptSegmentID
        }) else {
            return nil
        }
        return TranscriptTimestampFormatter.string(from: segment.startTime)
    }
}
