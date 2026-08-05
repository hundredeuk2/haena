import SwiftUI

/// Content pane for one project, switching between its meetings and its work state.
///
/// The two are separated by a picker rather than stacked, because the meeting list is a selection
/// list driving the third pane while the work-state pane is a scrolling review surface — putting
/// both in one scroll view would fight SwiftUI and bury whichever came second.
struct ProjectDetailView: View {
    let project: Project
    @Binding var selectedMeetingID: Meeting.ID?
    let deletionErrorMessage: String?
    let onDeleteProject: () async -> Void
    let reviewService: WorkStateReviewService
    let onWorkStateChanged: () async -> Void
    /// Defaulted rather than injected from the browser: the real pasteboard is what the app always
    /// wants, and the seam exists for tests of the copy boundary, not for the view hierarchy.
    var pasteboardWriter: any PasteboardWriter = SystemPasteboardWriter()
    var fileExporter: any MarkdownFileExporter = SavePanelMarkdownExporter()

    @State private var isConfirmingDeletion = false
    @State private var pane: Pane = .status

    private let dateFormatter = MeetingDateFormatter()

    private enum Pane: String, CaseIterable, Identifiable {
        case status
        case meetings
        case workState

        var id: String { rawValue }
    }

    private var statusSummary: ProjectStatusSummary {
        ProjectStatusSummary(project: project)
    }

    private var sortedMeetings: [Meeting] {
        ProjectBrowserQueryService.sortedMeetings(project.meetings)
    }

    private var pendingProposalCount: Int {
        WorkStateInbox.pendingProposals(in: project).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(project.name)
                    .font(.title2)
                    .bold()
                    .accessibilityIdentifier("project-detail-name")

                Spacer()

                Button("프로젝트 삭제", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .accessibilityIdentifier("delete-project-button")
            }

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

            if let deletionErrorMessage {
                Text(deletionErrorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("project-deletion-error-message")
            }

            Divider()

            Picker("표시", selection: $pane) {
                Text("현재 상태").tag(Pane.status)
                Text("회의").tag(Pane.meetings)
                Text(pendingProposalCount == 0 ? "업무 상태" : "업무 상태 (\(pendingProposalCount))")
                    .tag(Pane.workState)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("project-detail-pane-picker")

            switch pane {
            case .status:
                ProjectStatusView(
                    summary: statusSummary,
                    participantsByMeeting: participants(forMeeting:),
                    onOpenWorkState: { pane = .workState },
                    makeMarkdown: exportMarkdown,
                    exportFilename: ProjectExportFilename.markdownFilename(for: project.name),
                    pasteboardWriter: pasteboardWriter,
                    fileExporter: fileExporter
                )

            case .meetings:
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

            case .workState:
                WorkStateReviewView(
                    project: project,
                    reviewService: reviewService,
                    onChanged: onWorkStateChanged
                )
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-detail-screen")
        // Selecting a different project in the sidebar reuses this view rather than rebuilding it,
        // so the pane has to be sent back to 현재 상태 explicitly — otherwise the second project a
        // user opens inherits whichever tab they left the first one on.
        .onChange(of: project.id) { _, _ in
            pane = .status
        }
        .sheet(isPresented: $isConfirmingDeletion) {
            DeletionConfirmationView(
                title: "“\(project.name)” 프로젝트를 삭제할까요?",
                message: "포함된 회의 \(project.meetings.count)개와 관련 업무 상태가 함께 삭제됩니다.\n이 작업은 앱에서 복구할 수 없습니다.",
                confirmButtonIdentifier: "confirm-delete-project-button",
                cancelButtonIdentifier: "cancel-delete-project-button",
                onConfirm: {
                    await onDeleteProject()
                    isConfirmingDeletion = false
                },
                onCancel: {
                    isConfirmingDeletion = false
                }
            )
        }
    }

    private func participants(forMeeting meetingID: UUID) -> [Participant] {
        project.meetings.first { $0.id == meetingID }?.participants ?? []
    }

    /// Built fresh each time the user asks for it, from one timestamp so the document's header and
    /// its overdue markers agree, and from the uncapped summary so the export is the whole project
    /// state rather than the three-per-section preview the screen shows.
    private func exportMarkdown() -> String {
        let now = Date()
        return ProjectMarkdownRenderer().render(
            project: project,
            summary: .complete(project: project, referenceDate: now),
            generatedAt: now
        )
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
