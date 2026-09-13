import Foundation

/// Presentation-only identity. No destination is a domain status or a persistence key.
enum AppShellDestination: String, CaseIterable, Identifiable {
    case home, review, briefs, transcripts, projects

    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .home: return L10n.text("홈")
        case .review: return L10n.text("검토")
        case .briefs: return L10n.text("브리프")
        case .transcripts: return L10n.text("원문")
        case .projects: return L10n.text("프로젝트")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .review: return "checklist"
        case .briefs: return "rectangle.stack"
        case .transcripts: return "text.alignleft"
        case .projects: return "folder"
        }
    }
}

/// One window's selection survives rail navigation. Deep links are explicit one-shot requests;
/// only those requests replace the selection and reset the destination pane.
struct AppShellNavigation: Equatable {
    private(set) var destination: AppShellDestination = .home
    var projectID: UUID?
    var meetingID: UUID?
    private(set) var workStateSelection: ProjectWorkStateSelection?
    var actionItemID: UUID? { workStateSelection?.actionItemID }
    private(set) var projectPane: ProjectDetailPane = .status
    private(set) var meetingPane: MeetingDetailPane = .initial
    private(set) var requestID = UUID()

    mutating func select(_ destination: AppShellDestination) {
        self.destination = destination
        workStateSelection = nil
        if destination == .transcripts { meetingPane = .transcript }
        if destination == .projects { projectPane = .status }
    }

    mutating func open(_ request: BrowserDestination) {
        projectID = request.projectID
        meetingID = request.meetingID
        workStateSelection = request.selection
        projectPane = request.pane
        meetingPane = .initial
        requestID = UUID()
        switch request.target {
        case .projectStatus, .approvedWorkState: destination = .projects
        case .pendingReview: destination = .review
        case .meetings: destination = .transcripts
        }
    }

    mutating func selectProject(_ id: UUID?) {
        guard projectID != id else { return }
        projectID = id
        meetingID = nil
        workStateSelection = nil
        projectPane = .status
        requestID = UUID()
    }

    mutating func validate(in projects: [Project]) {
        let selection = BrowserInitialSelection.resolve(projectID: projectID, meetingID: meetingID, in: projects)
        projectID = selection.projectID
        meetingID = selection.meetingID
        if projectID == nil { workStateSelection = nil }
    }
}
