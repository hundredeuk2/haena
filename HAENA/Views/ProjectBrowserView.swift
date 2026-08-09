import SwiftUI

/// Root of the "프로젝트 보기" flow: a 3-pane macOS browser (projects → meetings → meeting
/// detail) reading from `ProjectRepository` through the stateless `ProjectBrowserQueryService`.
/// Owns only UI state (`@State`); all repository access and sorting stay in the query service.
/// Deletion (`ProjectDeletionService`) is orchestrated here too, since this is the one place
/// that already owns the loaded project list and the sidebar/content/detail selection state
/// that must stay consistent after something is removed.
struct ProjectBrowserView: View {
    let repository: any ProjectRepository
    let extractor: any WorkStateExtractor
    /// Supplied so deleting a project or meeting also removes its stored audio, and so the meeting
    /// pane can find the file to play. Defaulted to nil for previews and for call sites that
    /// predate audio import.
    var audioAssetStore: AudioAssetStore?
    /// Passed through to the meeting pane, which makes one player per meeting.
    var makeAudioPlayer: () -> any MeetingAudioPlayer = { AVFoundationMeetingAudioPlayer() }
    /// Where to land when the browser opens, for a caller that already knows — the home screen
    /// tapping a row. Nil opens on nothing selected, as before.
    var initialProjectID: UUID?
    var initialPane: ProjectDetailPane = .status

    @Environment(\.dismiss) private var dismiss

    @State private var loadState: ProjectBrowserLoadState = .idle
    @State private var selectedProjectID: Project.ID?
    @State private var selectedMeetingID: Meeting.ID?
    @State private var showingPasteTranscript = false
    @State private var projectDeletionError: String?
    @State private var meetingDeletionError: String?

    private var queryService: ProjectBrowserQueryService {
        ProjectBrowserQueryService(repository: repository)
    }

    private var deletionService: ProjectDeletionService {
        ProjectDeletionService(repository: repository, assetStore: audioAssetStore)
    }

    private var reviewService: WorkStateReviewService {
        WorkStateReviewService(repository: repository)
    }

    private var speakerConfirmationService: SpeakerConfirmationService {
        SpeakerConfirmationService(repository: repository)
    }

    private var selectedProject: Project? {
        guard case .loaded(let projects) = loadState else {
            return nil
        }
        return projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            if let selectedProject {
                ProjectDetailView(
                    project: selectedProject,
                    selectedMeetingID: $selectedMeetingID,
                    deletionErrorMessage: projectDeletionError,
                    onDeleteProject: {
                        await confirmDeleteProject(selectedProject.id)
                    },
                    reviewService: reviewService,
                    // Reload rather than mutating the local copy, so what the review list shows is
                    // always what was actually persisted.
                    onWorkStateChanged: {
                        await load()
                    },
                    requestedPane: selectedProjectID == initialProjectID ? initialPane : nil
                )
            } else {
                Text("프로젝트를 선택해주세요.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            if let selectedProject,
               let meeting = selectedProject.meetings.first(where: { $0.id == selectedMeetingID }) {
                MeetingDetailView(
                    meeting: meeting,
                    deletionErrorMessage: meetingDeletionError,
                    onDeleteMeeting: {
                        await confirmDeleteMeeting(meeting.id, from: selectedProject.id)
                    },
                    speakerConfirmation: speakerConfirmationService,
                    // Reload rather than mutating the local copy, so the transcript always shows
                    // what was actually persisted.
                    onSpeakersChanged: {
                        await load()
                    },
                    audioAssetStore: audioAssetStore,
                    makeAudioPlayer: makeAudioPlayer
                )
            } else {
                Text("회의를 선택해주세요.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-browser-screen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("닫기") {
                    dismiss()
                }
                .accessibilityIdentifier("close-project-browser-button")
            }
        }
        .task {
            await load()
        }
        .onChange(of: showingPasteTranscript) { _, isShowing in
            guard !isShowing else { return }
            Task { await load() }
        }
        .onChange(of: selectedProjectID) { _, _ in
            validateMeetingSelection()
        }
        .sheet(isPresented: $showingPasteTranscript) {
            PasteTranscriptView(
                service: TextMeetingCaptureService(repository: repository),
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor)
            )
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView("불러오는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .accessibilityIdentifier("project-browser-error-message")
                Button("다시 시도") {
                    Task { await load() }
                }
                .accessibilityIdentifier("project-browser-retry-button")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            VStack(spacing: 12) {
                Text("아직 저장된 프로젝트가 없습니다.")
                Text("텍스트 회의록을 추가해 첫 프로젝트를 만들어보세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("텍스트 회의록 붙여넣기") {
                    showingPasteTranscript = true
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project-browser-empty-state")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let projects):
            List(projects, selection: $selectedProjectID) { project in
                ProjectRowView(project: project)
                    .tag(project.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-row-\(project.id.uuidString)")
            }
            .accessibilityIdentifier("project-list")
        }
    }

    private func load() async {
        loadState = .loading
        do {
            let projects = try await queryService.loadProjects()
            loadState = projects.isEmpty ? .empty : .loaded(projects)
            applyInitialSelection(against: projects)
            validateSelection(against: projects)
        } catch {
            loadState = .failed("프로젝트를 불러오지 못했습니다.")
        }
    }

    /// Selects the project a caller asked to open, once and only while nothing else is selected —
    /// a reload triggered by approving something must not drag the user back to where they came in.
    /// A project that no longer exists is simply not selected; `validateSelection` then applies.
    private func applyInitialSelection(against projects: [Project]) {
        guard selectedProjectID == nil,
              let initialProjectID,
              projects.contains(where: { $0.id == initialProjectID }) else {
            return
        }
        selectedProjectID = initialProjectID
    }

    /// Clears any selection that no longer points at something in `projects` — e.g. after a
    /// deletion, or simply because the on-disk state changed since the last load.
    private func validateSelection(against projects: [Project]) {
        guard let selectedProjectID else {
            return
        }
        guard let project = projects.first(where: { $0.id == selectedProjectID }) else {
            self.selectedProjectID = nil
            self.selectedMeetingID = nil
            return
        }
        if let selectedMeetingID, !project.meetings.contains(where: { $0.id == selectedMeetingID }) {
            self.selectedMeetingID = nil
        }
    }

    /// Called when the sidebar selection changes: a meeting selected under a previous project
    /// must not silently carry over to a different project.
    private func validateMeetingSelection() {
        guard let selectedMeetingID else {
            return
        }
        guard let selectedProject, selectedProject.meetings.contains(where: { $0.id == selectedMeetingID }) else {
            self.selectedMeetingID = nil
            return
        }
    }

    private func confirmDeleteProject(_ projectID: UUID) async {
        projectDeletionError = nil
        do {
            try await deletionService.deleteProject(id: projectID)
            if selectedProjectID == projectID {
                selectedProjectID = nil
                selectedMeetingID = nil
            }
            await load()
        } catch {
            projectDeletionError = "프로젝트를 삭제하지 못했습니다."
        }
    }

    private func confirmDeleteMeeting(_ meetingID: UUID, from projectID: UUID) async {
        meetingDeletionError = nil
        do {
            try await deletionService.deleteMeeting(meetingID: meetingID, fromProjectID: projectID)
            if selectedMeetingID == meetingID {
                selectedMeetingID = nil
            }
            await load()
        } catch {
            meetingDeletionError = "회의를 삭제하지 못했습니다."
        }
    }
}

private enum ProjectBrowserLoadState: Equatable {
    case idle
    case loading
    case loaded([Project])
    case empty
    case failed(String)
}

private struct ProjectRowView: View {
    let project: Project

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
                .accessibilityIdentifier("project-name-\(project.id.uuidString)")

            if !project.summary.isEmpty {
                Text(project.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(MeetingCountDisplay.label(count: project.meetings.count))
                    .accessibilityIdentifier("project-meeting-count-\(project.id.uuidString)")
                Spacer()
                Text(dateFormatter.string(from: project.updatedAt))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ProjectBrowserView(repository: InMemoryProjectRepository(), extractor: DeterministicWorkStateExtractor())
}
