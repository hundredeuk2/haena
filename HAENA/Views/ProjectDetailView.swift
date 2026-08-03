import SwiftUI

/// Content pane showing one project's summary/dates and its meetings, sorted by
/// `ProjectBrowserQueryService.sortedMeetings`. No AI-extracted sections (Decision, ActionItem,
/// OpenQuestion, AgendaItem) are shown yet — nothing has ever produced them.
struct ProjectDetailView: View {
    let project: Project
    @Binding var selectedMeetingID: Meeting.ID?

    private let dateFormatter = MeetingDateFormatter()

    private var sortedMeetings: [Meeting] {
        ProjectBrowserQueryService.sortedMeetings(project.meetings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project.name)
                .font(.title2)
                .bold()
                .accessibilityIdentifier("project-detail-name")

            if !project.summary.isEmpty {
                Text(project.summary)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Text("생성 \(dateFormatter.string(from: project.createdAt))")
                Text("수정 \(dateFormatter.string(from: project.updatedAt))")
                Text(MeetingCountDisplay.label(count: project.meetings.count))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if sortedMeetings.isEmpty {
                Text("저장된 회의가 없습니다.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-list-empty-state")
            } else {
                List(sortedMeetings, selection: $selectedMeetingID) { meeting in
                    MeetingRowView(meeting: meeting)
                        .tag(meeting.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("meeting-row-\(meeting.id.uuidString)")
                }
                .accessibilityIdentifier("meeting-list")
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-detail-screen")
    }
}

private struct MeetingRowView: View {
    let meeting: Meeting

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.headline)
            HStack(spacing: 8) {
                Text(dateFormatter.string(from: meeting.occurredAt))
                Text(MeetingSourceTypeDisplay.label(for: meeting.sourceType))
                Text("원문 \(meeting.transcriptSegments.count)개")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
