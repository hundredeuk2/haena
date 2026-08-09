import SwiftUI

/// The app's opening screen: what needs attention across every project, in one place.
///
/// Read-only by design. Nothing is approved, edited, or dismissed here — every row leads to the
/// screen that already owns that action, so there is exactly one place in the app where a proposal
/// can be judged. It owns no filtering or ordering rules either; those all live in `HomeSummary`.
struct HomeView: View {
    let repository: any ProjectRepository
    /// Changed by the owner whenever something might have altered stored data — closing a capture
    /// sheet, returning from the browser — which re-runs the load.
    let reloadToken: UUID
    let onRecord: () -> Void
    let onImportAudio: () -> Void
    let onPasteTranscript: () -> Void
    let onBrowseProjects: () -> Void
    /// Opens an existing screen for that project. The home never presents review UI of its own.
    let onOpenProject: (UUID, ProjectDetailPane) -> Void

    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded(HomeSummary)
        case failed(String)
    }

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            switch loadState {
            case .loading:
                ProgressView("불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .accessibilityIdentifier("home-error-message")
                    Button("다시 시도") {
                        Task { await load() }
                    }
                    .accessibilityIdentifier("home-retry-button")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let summary):
                summaryBody(summary)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-screen")
        .task(id: reloadToken) {
            await load()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppInfo.name)
                .font(.largeTitle)
                .bold()
                .accessibilityIdentifier("product-name")

            HStack(spacing: 12) {
                Button("녹음 시작") {
                    onRecord()
                }
                .accessibilityIdentifier("record-button")

                Button("파일 불러오기") {
                    onImportAudio()
                }
                .accessibilityIdentifier("import-button")

                Button("텍스트 회의록 붙여넣기") {
                    onPasteTranscript()
                }
                .accessibilityIdentifier("paste-transcript-button")

                Spacer(minLength: 0)

                Button("프로젝트 보기") {
                    onBrowseProjects()
                }
                .accessibilityIdentifier("browse-projects-button")
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryBody(_ summary: HomeSummary) -> some View {
        if summary.projectCount == 0 {
            VStack(spacing: 12) {
                Text("아직 저장된 프로젝트가 없습니다.")
                Text("회의를 녹음하거나 음성 파일을 불러오면 여기에 확인할 내용이 모입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-empty-state")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pendingSection(summary)
                    workSection(summary)
                    questionSection(summary)
                    agendaSection(summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Always rendered, even at zero: an area that disappears when it empties leaves the user
    /// unable to tell "nothing to review" from "this app does not track that".
    private func pendingSection(_ summary: HomeSummary) -> some View {
        HomeSection(
            title: "확인 필요",
            countLabel: "\(summary.pendingProposalCount)건",
            identifier: "home-pending"
        ) {
            if summary.pendingProposalCount == 0 {
                Text("확인이 필요한 AI 제안이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-pending-empty")
            } else {
                ForEach(summary.pendingProposalsByProject.items) { entry in
                    HomeRowButton(identifier: "home-pending-row-\(entry.projectID.uuidString)") {
                        onOpenProject(entry.projectID, .workState)
                    } label: {
                        HStack {
                            Text(entry.projectName)
                            Spacer(minLength: 12)
                            Text("\(entry.count)건")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                hiddenCountLabel(
                    summary.pendingProposalsByProject.hiddenCount,
                    unit: "개 프로젝트",
                    identifier: "home-pending-more"
                )
            }
        }
    }

    private func workSection(_ summary: HomeSummary) -> some View {
        HomeSection(
            title: "진행 업무",
            countLabel: "\(summary.activeActionItems.totalCount)건",
            identifier: "home-work"
        ) {
            if summary.activeActionItems.isEmpty {
                Text("진행 중인 업무가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-work-empty")
            } else {
                ForEach(summary.activeActionItems.items) { entry in
                    HomeRowButton(identifier: "home-work-row-\(entry.id.uuidString)") {
                        onOpenProject(entry.projectID, .workState)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.actionItem.title)

                            HStack(spacing: 12) {
                                // Named rather than assumed: there is no signed-in user, so this
                                // list is everyone's work and each row has to say whose.
                                Text(entry.assigneeName ?? "담당자 미정")
                                if let dueLabel = WorkStateDisplay.dueDateLabel(
                                    entry.actionItem.dueDate,
                                    formatter: dateFormatter
                                ) {
                                    Text(dueLabel)
                                        .foregroundStyle(
                                            summary.isOverdue(entry.actionItem)
                                                ? AnyShapeStyle(.red)
                                                : AnyShapeStyle(.secondary)
                                        )
                                }
                                Text(entry.projectName)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                hiddenCountLabel(
                    summary.activeActionItems.hiddenCount,
                    unit: "건",
                    identifier: "home-work-more"
                )
            }
        }
    }

    private func questionSection(_ summary: HomeSummary) -> some View {
        HomeSection(
            title: "미해결 질문",
            countLabel: "\(summary.unresolvedQuestions.totalCount)건",
            identifier: "home-questions"
        ) {
            if summary.unresolvedQuestions.isEmpty {
                Text("미해결 질문이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-questions-empty")
            } else {
                ForEach(summary.unresolvedQuestions.items) { entry in
                    HomeRowButton(identifier: "home-question-row-\(entry.id.uuidString)") {
                        onOpenProject(entry.projectID, .workState)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.value.question)
                            Text(entry.projectName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                hiddenCountLabel(
                    summary.unresolvedQuestions.hiddenCount,
                    unit: "건",
                    identifier: "home-questions-more"
                )
            }
        }
    }

    private func agendaSection(_ summary: HomeSummary) -> some View {
        HomeSection(
            title: "다음 아젠다",
            countLabel: "\(summary.upcomingAgendaItems.totalCount)건",
            identifier: "home-agenda"
        ) {
            if summary.upcomingAgendaItems.isEmpty {
                Text("다음 아젠다가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-agenda-empty")
            } else {
                ForEach(summary.upcomingAgendaItems.items) { entry in
                    HomeRowButton(identifier: "home-agenda-row-\(entry.id.uuidString)") {
                        onOpenProject(entry.projectID, .workState)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.value.title)
                            Text(entry.projectName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                hiddenCountLabel(
                    summary.upcomingAgendaItems.hiddenCount,
                    unit: "건",
                    identifier: "home-agenda-more"
                )
            }
        }
    }

    @ViewBuilder
    private func hiddenCountLabel(_ hidden: Int, unit: String, identifier: String) -> some View {
        if hidden > 0 {
            Text("외 \(hidden)\(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - Loading

    private func load() async {
        loadState = .loading
        do {
            let projects = try await ProjectBrowserQueryService(repository: repository).loadProjects()
            loadState = .loaded(HomeSummary(projects: projects))
        } catch {
            loadState = .failed("저장된 내용을 불러오지 못했습니다.")
        }
    }
}

/// A titled area with its own total, so every area reads the same way.
private struct HomeSection<Content: View>: View {
    let title: String
    let countLabel: String
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-count")
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier)-section")
    }
}

/// A row that navigates. Plain styling so a list of these reads as content rather than a wall of
/// buttons, while still being a real control for keyboard and VoiceOver.
private struct HomeRowButton<Label: View>: View {
    let identifier: String
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
