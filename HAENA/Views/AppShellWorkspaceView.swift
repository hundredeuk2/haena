import SwiftUI

/// Composition of the existing project, review, meeting and Brief surfaces. Repository queries
/// and verdict/deletion services remain authoritative; this view owns only a loaded snapshot.
struct AppShellWorkspaceView: View {
    @Binding var navigation: AppShellNavigation
    let repository: any ProjectRepository
    let reviewService: WorkStateReviewService
    let manualBriefService: ManualContinuityBriefService
    let transitionReviewService: WorkStateTransitionReviewService
    let deletionService: ProjectDeletionService
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let reminderService: ActionItemReminderService
    let audioAssetStore: AudioAssetStore
    let makeAudioPlayer: () -> any MeetingAudioPlayer
    let reanalysisService: MeetingReanalysisService
    let reloadToken: UUID
    let onPaste: () -> Void
    let onChanged: () -> Void

    @State private var projects: [Project] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var deletionError: String?

    private struct LoadRequest: Equatable {
        let destination: AppShellDestination
        let reloadToken: UUID
        let requestID: UUID
    }

    private var project: Project? { projects.first { $0.id == navigation.projectID } }
    private var meeting: Meeting? { project?.meetings.first { $0.id == navigation.meetingID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(navigation.destination.title).font(.title2).bold()
                Spacer()
                if !projects.isEmpty {
                    Picker(L10n.text("프로젝트"), selection: Binding(
                        get: { navigation.projectID }, set: { navigation.selectProject($0) }
                    )) {
                        Text(L10n.text("프로젝트를 선택해주세요.")).tag(UUID?.none)
                        ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("shell-project-picker")
                }
            }
            .padding()
            Divider()
            if let loadError {
                VStack {
                    Text(L10n.text(loadError))
                    Button(L10n.text("다시 시도")) { Task { await load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loaded {
                ProgressView(L10n.text("불러오는 중…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project {
                selectedContent(project)
            } else {
                projectSelection
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-browser-screen")
        .task(id: LoadRequest(destination: navigation.destination, reloadToken: reloadToken,
                              requestID: navigation.requestID)) {
            if navigation.destination != .home { await load() }
        }
        .onChange(of: navigation.projectID) { _, _ in deletionError = nil }
    }

    private var projectSelection: some View {
        VStack(spacing: 16) {
            Label(navigation.destination.title, systemImage: navigation.destination.symbol)
                .font(.headline)
            Text(L10n.text("프로젝트를 선택해주세요."))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("shell-selection-guidance")
            if projects.isEmpty {
                VStack(spacing: 12) {
                    Text(L10n.text("아직 저장된 프로젝트가 없습니다."))
                    Button(L10n.text("텍스트 회의록 붙여넣기"), action: onPaste)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("project-browser-empty-state")
            } else {
                List(projects) { project in
                    Button { navigation.selectProject(project.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            Text(UIMeetingCountDisplay.label(count: project.meetings.count))
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project-row-\(project.id.uuidString)")
                }.accessibilityIdentifier("project-list")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell-empty-\(navigation.destination.rawValue)")
    }

    @ViewBuilder private func selectedContent(_ project: Project) -> some View {
        switch navigation.destination {
        case .home: EmptyView()
        case .review:
            WorkStateReviewView(
                project: project, reviewService: reviewService,
                profileRepository: profileRepository, reminderRepository: reminderRepository,
                reminderService: reminderService, onChanged: refresh
            ).id(navigation.requestID)
        case .briefs:
            ManualContinuityBriefView(
                projectID: project.id, briefService: manualBriefService,
                reviewService: transitionReviewService, workStateReviewService: reviewService,
                onChanged: refresh, onClose: { navigation.select(.projects) }
            ).id(project.id)
        case .transcripts:
            if let meeting { meetingContent(project, meeting) }
            else { meetingSelection(project) }
        case .projects:
            if navigation.projectPane == .workState {
                ProjectWorkStateView(project: project, reviewService: reviewService,
                    profileRepository: profileRepository, reminderRepository: reminderRepository,
                    reminderService: reminderService, onChanged: refresh,
                    selection: navigation.workStateSelection).id(navigation.requestID)
            } else if let meeting { meetingContent(project, meeting) }
            else {
                ProjectDetailView(
                    project: project, selectedMeetingID: $navigation.meetingID,
                    deletionErrorMessage: deletionError,
                    onDeleteProject: { await deleteProject(project.id) },
                    reviewService: reviewService, manualBriefService: manualBriefService,
                    transitionReviewService: transitionReviewService,
                    profileRepository: profileRepository, reminderRepository: reminderRepository,
                    reminderService: reminderService, onWorkStateChanged: refresh,
                    requestedPane: navigation.projectPane,
                    requestedActionItemID: navigation.actionItemID,
                    requestedWorkStateSelection: navigation.workStateSelection,
                    onOpenPendingReview: { navigation.open(.init(projectID: project.id, target: .pendingReview)) }
                ).id(navigation.requestID)
            }
        }
    }

    private func meetingSelection(_ project: Project) -> some View {
        VStack {
            Text(L10n.text("회의를 선택해주세요."))
                .accessibilityIdentifier("shell-meeting-guidance")
            if project.meetings.isEmpty { Text(L10n.text("저장된 회의가 없습니다.")) }
            List(ProjectBrowserQueryService.sortedMeetings(project.meetings)) { meeting in
                Button(meeting.title) { navigation.meetingID = meeting.id }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("meeting-row-\(meeting.id.uuidString)")
            }.accessibilityIdentifier("meeting-list")
        }.padding()
    }

    private func meetingContent(_ project: Project, _ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            Button(L10n.text("회의")) { navigation.meetingID = nil }
                .accessibilityIdentifier("shell-back-to-meetings")
                .padding(.top, 8)
            MeetingDetailView(
                project: project, meeting: meeting, deletionErrorMessage: deletionError,
                onDeleteMeeting: { await deleteMeeting(meeting.id, projectID: project.id) },
                reviewService: reviewService, onWorkStateChanged: refresh,
                speakerConfirmation: SpeakerConfirmationService(repository: repository),
                onSpeakersChanged: refresh, audioAssetStore: audioAssetStore,
                makeAudioPlayer: makeAudioPlayer, reanalysis: reanalysisService,
                requestedPane: navigation.meetingPane
            ).id(meeting.id)
        }
    }

    private func load() async {
        do {
            let snapshot = try await ProjectBrowserQueryService(repository: repository).loadProjects()
            guard !Task.isCancelled else { return }
            projects = snapshot
            navigation.validate(in: projects)
            loaded = true
            loadError = nil
        } catch { loadError = "프로젝트를 불러오지 못했습니다." }
    }

    private func refresh() async {
        await load()
        // Explicit changes retain the old browser's reconciliation boundary. Merely opening
        // the Brief or selecting a rail destination performs no reconciliation writes.
        await reminderService.reconcile()
        onChanged()
    }

    private func deleteProject(_ id: UUID) async {
        do { try await deletionService.deleteProject(id: id); await refresh() }
        catch { deletionError = "프로젝트를 삭제하지 못했습니다." }
    }

    private func deleteMeeting(_ id: UUID, projectID: UUID) async {
        do { try await deletionService.deleteMeeting(meetingID: id, fromProjectID: projectID); await refresh() }
        catch { deletionError = "회의를 삭제하지 못했습니다." }
    }
}
