import Foundation

/// A single stored-state resume row, not an extraction pipeline or a new persisted status.
struct HomeMeetingResume: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case needsReview, savedResults, savedMeeting

        var localizationKey: String {
            switch self {
            case .needsReview: "저장 상태: 검토 필요"
            case .savedResults: "저장 상태: 검토할 제안 없음"
            case .savedMeeting: "저장 상태: 회의 저장됨 · 결과 없음"
            }
        }
    }

    let projectID: UUID
    let meetingID: UUID
    let title: String
    let stage: Stage
    let pendingCount: Int

    var destination: BrowserDestination {
        .results(of: CaptureDestination(projectID: projectID, meetingID: meetingID))
    }

    static func latest(in projects: [Project]) -> Self? {
        let candidates = projects.flatMap { project in
            project.meetings.filter { $0.projectID == project.id }.map { (project, $0) }
        }.sorted { lhs, rhs in
            if lhs.1.occurredAt != rhs.1.occurredAt { return lhs.1.occurredAt > rhs.1.occurredAt }
            if lhs.1.createdAt != rhs.1.createdAt { return lhs.1.createdAt > rhs.1.createdAt }
            if lhs.0.id != rhs.0.id { return lhs.0.id.uuidString < rhs.0.id.uuidString }
            return lhs.1.id.uuidString < rhs.1.id.uuidString
        }
        guard let (project, meeting) = candidates.first else { return nil }
        let summary = MeetingWorkStateSummary(project: project, meetingID: meeting.id)
        let pending = summary.decisions.needsReview.count + summary.actionItems.needsReview.count
            + summary.openQuestions.needsReview.count + summary.agendaItems.needsReview.count
        let total = summary.decisions.totalCount + summary.actionItems.totalCount
            + summary.openQuestions.totalCount + summary.agendaItems.totalCount
        return Self(projectID: project.id, meetingID: meeting.id, title: meeting.title,
                    stage: pending > 0 ? .needsReview : (total > 0 ? .savedResults : .savedMeeting),
                    pendingCount: pending)
    }
}
