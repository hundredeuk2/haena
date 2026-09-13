import Foundation

/// UI ownership and exact selection, never a persisted domain discriminator.
enum ProjectWorkStateSelection: Hashable, Sendable {
    case decision(UUID), actionItem(UUID), openQuestion(UUID), agendaItem(UUID)
    var actionItemID: UUID? { if case .actionItem(let id) = self { return id }; return nil }
    var accessibilityKey: String {
        switch self {
        case .decision(let id): "decision-\(id.uuidString)"
        case .actionItem(let id): "actionItem-\(id.uuidString)"
        case .openQuestion(let id): "openQuestion-\(id.uuidString)"
        case .agendaItem(let id): "agendaItem-\(id.uuidString)"
        }
    }
    func proposal(in project: Project) -> WorkStateProposal? {
        switch self {
        case .decision(let id): WorkStateInbox.confirmedDecisions(in: project).first { $0.id == id }.map(WorkStateProposal.decision)
        case .actionItem(let id): WorkStateInbox.activeActionItems(in: project).first { $0.id == id }.map(WorkStateProposal.actionItem)
        case .openQuestion(let id): WorkStateInbox.reviewedOpenQuestions(in: project).first { $0.id == id }.map(WorkStateProposal.openQuestion)
        case .agendaItem(let id): WorkStateInbox.reviewedAgendaItems(in: project).first { $0.id == id }.map(WorkStateProposal.agendaItem)
        }
    }
}

enum BrowserTarget: Equatable, Sendable {
    case projectStatus, meetings, pendingReview, approvedWorkState(ProjectWorkStateSelection?)
}

/// Where the project browser should land when something opens it: the home screen tapping a row,
/// or a finished capture handing over the meeting it just created.
struct BrowserDestination: Equatable, Sendable {
    let projectID: UUID
    /// Set when the caller knows which meeting, not only which project.
    var meetingID: UUID?
    /// Set when the caller can name the exact task the user pressed — the home's 지금 할 일 card.
    ///
    /// A one-shot request to look at something, not a filter and not stored state: 업무 상태 opens
    /// scrolled to that task and then behaves exactly as it always does. Making it anything more
    /// would mean the user could not navigate away from the item the home picked for them.
    let target: BrowserTarget
    var actionItemID: UUID? { selection?.actionItemID }
    var selection: ProjectWorkStateSelection? {
        if case .approvedWorkState(let selection) = target { return selection }; return nil
    }
    var pane: ProjectDetailPane {
        switch target {
        case .projectStatus: .status
        case .meetings: .meetings
        case .pendingReview, .approvedWorkState: .workState
        }
    }

    init(projectID: UUID, meetingID: UUID? = nil, target: BrowserTarget) {
        self.projectID = projectID; self.meetingID = meetingID; self.target = target
    }

    /// Legacy project-pane entry remains explicitly project-owned. Pending routes must say so.
    init(projectID: UUID, meetingID: UUID? = nil, actionItemID: UUID? = nil, pane: ProjectDetailPane) {
        self.projectID = projectID; self.meetingID = meetingID
        switch pane {
        case .status: target = .projectStatus
        case .meetings: target = .meetings
        case .workState: target = .approvedWorkState(actionItemID.map(ProjectWorkStateSelection.actionItem))
        }
    }

    /// Where a finished capture sends the user.
    ///
    /// The middle pane is the meeting list rather than 현재 상태, because that is the pane the
    /// selected meeting is visible in — landing on the project summary would show the user a
    /// screen that says nothing about the meeting they just made. The detail pane opens on
    /// 회의 결과 on its own; see `MeetingDetailPane.initial`.
    static func results(of capture: CaptureDestination) -> BrowserDestination {
        BrowserDestination(
            projectID: capture.projectID,
            meetingID: capture.meetingID,
            pane: .meetings
        )
    }

    /// Where the home's 지금 할 일 card sends the user.
    ///
    /// Pending recommendations belong to Review. Approved work belongs to Projects, with the
    /// exact typed object selection. Optional IDs never decide which screen owns the request.
    ///
    /// Only the task recommendation names an item. A review recommendation deliberately does not —
    /// it is about a pile of proposals, and singling one out would be the home making a judgement
    /// it has no basis for.
    static func nextAction(_ action: NextAction) -> BrowserDestination {
        switch action {
        case .review(let review):
            return BrowserDestination(projectID: review.projectID, target: .pendingReview)
        case .work(let work):
            return BrowserDestination(
                projectID: work.projectID,
                target: .approvedWorkState(.actionItem(work.actionItemID))
            )
        }
    }
}

/// What the browser actually selects when it opens, given what a caller asked for and what is
/// really in storage by then.
///
/// Extracted from the view so the "no longer there" cases can be exercised directly. A meeting can
/// be deleted between the capture finishing and the browser opening — from another window, or by
/// editing the store underneath — and none of those may crash or silently select the wrong thing.
enum BrowserInitialSelection: Equatable {
    /// Nothing a caller asked for could be honoured.
    case none
    case project(UUID)
    case meeting(projectID: UUID, meetingID: UUID)

    var projectID: UUID? {
        switch self {
        case .none: return nil
        case .project(let id): return id
        case .meeting(let projectID, _): return projectID
        }
    }

    var meetingID: UUID? {
        switch self {
        case .none, .project: return nil
        case .meeting(_, let meetingID): return meetingID
        }
    }

    /// Falls back one step at a time rather than all the way: a caller who asked for a meeting
    /// that is gone still lands on its project, which is where the user would look for it.
    static func resolve(
        projectID: UUID?,
        meetingID: UUID?,
        in projects: [Project]
    ) -> BrowserInitialSelection {
        guard let projectID, let project = projects.first(where: { $0.id == projectID }) else {
            return .none
        }
        guard let meetingID, project.meetings.contains(where: { $0.id == meetingID }) else {
            return .project(projectID)
        }
        return .meeting(projectID: projectID, meetingID: meetingID)
    }
}
