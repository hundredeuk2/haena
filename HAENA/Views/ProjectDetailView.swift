import SwiftUI

/// Which area of a project is showing. Declared at file scope rather than nested privately so a
/// caller can ask for one directly — the home screen opens a project already on its work state.
enum ProjectDetailPane: String, CaseIterable, Identifiable {
    case status
    case meetings
    case workState

    var id: String { rawValue }
}

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
    let manualBriefService: ManualContinuityBriefService?
    let transitionReviewService: WorkStateTransitionReviewService?
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let reminderService: ActionItemReminderService?
    let onWorkStateChanged: () async -> Void
    /// Defaulted rather than injected from the browser: the real pasteboard is what the app always
    /// wants, and the seam exists for tests of the copy boundary, not for the view hierarchy.
    var pasteboardWriter: any PasteboardWriter = SystemPasteboardWriter()
    var fileExporter: any MarkdownFileExporter = SavePanelMarkdownExporter()

    /// Set by a caller that already knows which area the user asked for — the home screen opening
    /// a project's work state, for instance. Nil leaves the pane at its normal default.
    var requestedPane: ProjectDetailPane?
    /// The task a caller wants the user to see — the home's 지금 할 일 card naming what it
    /// recommended. Taken up once, on the same first appearance as `requestedPane`.
    var requestedActionItemID: UUID?
    var requestedWorkStateSelection: ProjectWorkStateSelection?
    var onOpenPendingReview: (() -> Void)?
    @State private var workStateSelection: ProjectWorkStateSelection?

    @State private var isConfirmingDeletion = false
    @State private var isShowingManualBrief = false
    @State private var pane: ProjectDetailPane = .status

    private var dateFormatter: MeetingDateFormatter { MeetingDateFormatter(locale: AppLanguageSettings.shared.locale) }

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

                Button(L10n.text("프로젝트 삭제"), role: .destructive) {
                    isConfirmingDeletion = true
                }
                .accessibilityIdentifier("delete-project-button")
            }

            if !project.summary.isEmpty {
                Text(project.summary)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Text(L10n.format("생성 %@", String(describing: dateFormatter.string(from: project.createdAt))))
                Text(L10n.format("수정 %@", String(describing: dateFormatter.string(from: project.updatedAt))))
                Text(UIMeetingCountDisplay.label(count: project.meetings.count))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if manualBriefService != nil, transitionReviewService != nil {
                Button {
                    isShowingManualBrief = true
                } label: {
                    Label(L10n.text("다음 회의 준비"), systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("open-manual-continuity-brief-button")
            }

            if let deletionErrorMessage {
                Text(L10n.text(deletionErrorMessage))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("project-deletion-error-message")
            }

            Divider()

            Picker(L10n.text("표시"), selection: $pane) {
                Text(L10n.text("현재 상태")).tag(ProjectDetailPane.status)
                Text(L10n.text("회의")).tag(ProjectDetailPane.meetings)
                Text(pendingProposalCount == 0 ? L10n.text("업무 상태") : L10n.format("업무 상태 (%@)", String(describing: pendingProposalCount)))
                    .tag(ProjectDetailPane.workState)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("project-detail-pane-picker")

            switch pane {
            case .status:
                ProjectStatusView(
                    summary: statusSummary,
                    participantsByMeeting: participants(forMeeting:),
                    onOpenWorkState: { workStateSelection = nil; pane = .workState },
                    makeMarkdown: exportMarkdown,
                    exportFilename: ProjectExportFilename.markdownFilename(for: project.name),
                    pasteboardWriter: pasteboardWriter,
                    fileExporter: fileExporter,
                    onOpenReview: onOpenPendingReview,
                    onOpenObject: { workStateSelection = $0; pane = .workState }
                )

            case .meetings:
                if sortedMeetings.isEmpty {
                    Text(L10n.text("저장된 회의가 없습니다."))
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
                ProjectWorkStateView(
                    project: project,
                    reviewService: reviewService,
                    profileRepository: profileRepository,
                    reminderRepository: reminderRepository,
                    reminderService: reminderService,
                    onChanged: onWorkStateChanged,
                    selection: workStateSelection
                )
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-detail-screen")
        // Only on first appearance, and only when a caller asked: arriving from the home screen
        // lands on the area the user tapped rather than making them find it again.
        .onAppear {
            if let requestedPane {
                pane = requestedPane
            }
            workStateSelection = requestedWorkStateSelection ?? requestedActionItemID.map(ProjectWorkStateSelection.actionItem)
        }
        // Selecting a different project in the sidebar reuses this view rather than rebuilding it,
        // so the pane has to be sent back to 현재 상태 explicitly — otherwise the second project a
        // user opens inherits whichever tab they left the first one on. This deliberately wins over
        // `requestedPane`: that request was about the project the user arrived on, not this one.
        // The highlighted task goes with it, for exactly the same reason.
        .onChange(of: project.id) { _, _ in
            pane = .status
            workStateSelection = nil
        }
        // Leaving 업무 상태 is the user saying they are done with what the home sent them to look
        // at. Dropping it here is what keeps this a one-time hand-off rather than a mode.
        .onChange(of: pane) { _, newPane in
            if newPane != .workState {
                workStateSelection = nil
            }
        }
        .sheet(isPresented: $isConfirmingDeletion) {
            DeletionConfirmationView(
                title: L10n.format("“%@” 프로젝트를 삭제할까요?", String(describing: project.name)),
                message: L10n.format("포함된 회의 %@개와 관련 업무 상태가 함께 삭제됩니다.\n이 작업은 앱에서 복구할 수 없습니다.", String(describing: project.meetings.count)),
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
        .sheet(isPresented: $isShowingManualBrief) {
            if let manualBriefService, let transitionReviewService {
                ManualContinuityBriefView(
                    projectID: project.id,
                    briefService: manualBriefService,
                    reviewService: transitionReviewService,
                    // The very instance the AI 제안 inbox on this screen already uses.
                    workStateReviewService: reviewService,
                    onChanged: onWorkStateChanged,
                    onClose: { isShowingManualBrief = false }
                )
            }
        }
    }

    /// Ids are preserved and only names substituted, so an assignee stored against an anonymous
    /// speaker keeps resolving and starts showing the confirmed name.
    private func participants(forMeeting meetingID: UUID) -> [Participant] {
        project.meetings.first { $0.id == meetingID }?.displayRoster ?? []
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

    private var dateFormatter: MeetingDateFormatter { MeetingDateFormatter(locale: AppLanguageSettings.shared.locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.headline)
            HStack(spacing: 8) {
                Text(dateFormatter.string(from: meeting.occurredAt))
                Text(L10n.text(MeetingSourceTypeDisplay.label(for: meeting.sourceType)))
                Text(L10n.format("원문 %@개", String(describing: meeting.transcriptSegments.count)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
