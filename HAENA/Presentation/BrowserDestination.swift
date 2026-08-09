import Foundation

/// Where the project browser should land when something opens it: the home screen tapping a row,
/// or a finished capture handing over the meeting it just created.
struct BrowserDestination: Equatable, Sendable {
    let projectID: UUID
    /// Set when the caller knows which meeting, not only which project.
    var meetingID: UUID?
    let pane: ProjectDetailPane

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
