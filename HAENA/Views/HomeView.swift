import SwiftUI

/// The app's opening screen: what needs attention across every project, in one place.
///
/// Read-only by design. Nothing is approved, edited, or dismissed here — every row leads to the
/// screen that already owns that action. The one explicit Private-beta exception is the reminder
/// validation sample: when no eligible task exists, the user can add a clearly named local sample
/// and is taken to the existing work-state screen to operate it there.
struct HomeView: View {
    let repository: any ProjectRepository
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    /// Changed by the owner whenever something might have altered stored data — closing a capture
    /// sheet, returning from the browser — which re-runs the load.
    let reloadToken: UUID
    let onOpenProfile: () -> Void
    let onOpenAISettings: () -> Void
    let onRecord: () -> Void
    let onImportAudio: () -> Void
    let onPasteTranscript: () -> Void
    let onBrowseProjects: () -> Void
    /// Opens an existing screen at the place a row or the 지금 할 일 card points at. The home never
    /// presents review UI of its own, and every way out of it is one of these.
    let onOpen: (BrowserDestination) -> Void

    @State private var loadState: LoadState = .loading
    /// Which list the work area is showing. Session-only on purpose: this is a glance, not a saved
    /// filter, and persisting it would be one more piece of state to explain.
    @State private var showingAllWork = false
    @State private var isCreatingReminderSample = false
    @State private var reminderSampleError: String?

    private enum LoadState: Equatable {
        case loading
        case loaded(LoadedHome)
        case failed(String)
    }

    private struct LoadedHome: Equatable {
        let summary: HomeSummary
        let remindersByActionItem: [UUID: ActionItemReminder]
        let hasEligibleReminderTask: Bool
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

            case .loaded(let loaded):
                summaryBody(
                    loaded.summary,
                    reminders: loaded.remindersByActionItem,
                    hasEligibleReminderTask: loaded.hasEligibleReminderTask
                )
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

            profileRow
        }
    }

    /// An invitation, never a gate: the app is fully usable without a profile, so this states the
    /// situation and offers the screen rather than blocking the way in.
    @ViewBuilder
    private var profileRow: some View {
        HStack(spacing: 8) {
            if case .loaded(let loaded) = loadState, let name = loaded.summary.localUserName {
                let summary = loaded.summary
                Text(summary.isPersonalised ? "내 이름: \(name)" : "내 이름: \(name) · 연결된 참석자 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-profile-name")
            } else {
                Text("프로필 미설정")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-profile-unset")
            }

            Button("내 프로필") {
                onOpenProfile()
            }
            .accessibilityIdentifier("open-profile-button")

            Button("AI 설정") {
                onOpenAISettings()
            }
            .accessibilityIdentifier("open-ai-settings-button")

            Spacer(minLength: 0)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryBody(
        _ summary: HomeSummary,
        reminders: [UUID: ActionItemReminder],
        hasEligibleReminderTask: Bool
    ) -> some View {
        if summary.projectCount == 0 {
            VStack(spacing: 12) {
                Text("아직 저장된 프로젝트가 없습니다.")
                Text("회의를 녹음하거나 음성 파일을 불러오면 여기에 확인할 내용이 모입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                reminderSampleButton
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-empty-state")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !hasEligibleReminderTask {
                        reminderSampleCallout
                    }
                    nextActionCard(summary, reminders: reminders)
                    pendingSection(summary)
                    workSection(summary, reminders: reminders)
                    questionSection(summary)
                    agendaSection(summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var reminderSampleCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("알림을 검증할 확정된 내 업무가 없습니다.")
                .font(.headline)
            Text("기존 데이터는 그대로 두고, 내 프로필과 연결된 마감일 있는 샘플 업무 한 건을 추가합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            reminderSampleButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-sample-callout")
    }

    @ViewBuilder
    private var reminderSampleButton: some View {
        Button(isCreatingReminderSample ? "샘플 만드는 중…" : "알림 검증 샘플 만들기") {
            Task { await createReminderSample() }
        }
        .disabled(isCreatingReminderSample)
        .accessibilityIdentifier("create-reminder-sample-button")

        if let reminderSampleError {
            Text(reminderSampleError)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("reminder-sample-error")
        }
    }

    // MARK: - 지금 할 일

    /// One highlighted recommendation above the four areas, never a fifth list.
    ///
    /// The four areas below are a complete picture and answer "what is going on"; this answers the
    /// different question a user actually opens the app with — "what do I do now" — and it can only
    /// answer it with one thing, or honestly say it has nothing. Which one is `NextActionPolicy`'s
    /// decision, not this view's: everything here is rendering.
    private func nextActionCard(
        _ summary: HomeSummary,
        reminders: [UUID: ActionItemReminder]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("지금 할 일")
                .font(.headline)
                .accessibilityIdentifier("home-next-action-title")

            switch summary.nextAction {
            case .review(let review):
                reviewRecommendation(review)
            case .work(let work):
                workRecommendation(work, reminder: reminders[work.actionItemID])
            case nil:
                emptyRecommendation(summary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-next-action-card")
    }

    /// A count and the project it is in — never the proposals themselves, for the same reason
    /// 확인 필요 shows counts: judging a suggestion needs its evidence, and that lives on the
    /// review screen this leads to.
    private func reviewRecommendation(_ review: NextAction.Review) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("결과 검토 \(review.pendingCount)건")
                .font(.title3)
                .accessibilityIdentifier("home-next-action-headline")

            Text(review.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home-next-action-project")

            Button("검토하기") {
                onOpen(BrowserDestination.nextAction(.review(review)))
            }
            .accessibilityIdentifier("home-next-action-button")
        }
    }

    private func workRecommendation(_ work: NextAction.Work, reminder: ActionItemReminder?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.title)
                .font(.title3)
                .accessibilityIdentifier("home-next-action-headline")

            HStack(spacing: 12) {
                Text(work.projectName)
                    .accessibilityIdentifier("home-next-action-project")

                // Named even though this is by definition the user's own work: the card sits above
                // a list that names everybody, and a row that quietly omits the assignee reads as
                // unassigned rather than as mine.
                Text(work.assigneeName ?? "담당자 미정")
                    .accessibilityIdentifier("home-next-action-assignee")

                // Colour alone does not survive being unable to see it, so a passed deadline says
                // so in words as well — the same 지남 wording the project status screen uses.
                Text(work.isOverdue ? "\(work.dueDateLabel) · 지남" : work.dueDateLabel)
                    .foregroundStyle(work.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("home-next-action-due")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let reminder, reminder.status == .scheduled {
                Text("알림 · \(ReminderDateDisplay().string(from: reminder.fireAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-next-action-reminder")
            }

            Button("업무 보기") {
                onOpen(BrowserDestination.nextAction(.work(work)))
            }
            .accessibilityIdentifier("home-next-action-button")
        }
    }

    /// Nothing to recommend. The profile line below it is an aside, not a demotion of some lesser
    /// recommendation: with no linked participant the app genuinely cannot name the user's own
    /// work, and offering somebody else's instead is the one thing it must not do.
    @ViewBuilder
    private func emptyRecommendation(_ summary: HomeSummary) -> some View {
        Text("지금 확인할 일이 없습니다")
            .font(.title3)
            .accessibilityIdentifier("home-next-action-empty")

        if !summary.isPersonalised {
            HStack(spacing: 6) {
                Text("프로필에 참석자를 연결하면 내 업무를 추천할 수 있습니다.")
                Button("내 프로필") {
                    onOpenProfile()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("home-next-action-profile-hint")
        }
    }

    // MARK: - Areas

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
                        onOpen(BrowserDestination(projectID: entry.projectID, pane: .workState))
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

    /// Shows the user's own work once they have identified themselves, and everyone's otherwise.
    /// The full list stays one press away either way — the meetings involved other people, and
    /// hiding them behind a profile would lose information the user already had.
    private func workSection(
        _ summary: HomeSummary,
        reminders: [UUID: ActionItemReminder]
    ) -> some View {
        let showingMine = summary.isPersonalised && !showingAllWork
        let section = showingMine ? (summary.myActionItems ?? summary.activeActionItems) : summary.activeActionItems

        return HomeSection(
            title: showingMine ? "내 업무" : "진행 업무",
            countLabel: "\(section.totalCount)건",
            identifier: "home-work"
        ) {
            if summary.isPersonalised {
                Button(showingAllWork ? "내 업무만 보기" : "전체 진행 업무 보기") {
                    showingAllWork.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("toggle-work-scope-button")
            } else {
                // Non-blocking: it says what is missing and where to fix it, and the list below is
                // unaffected either way.
                HStack(spacing: 6) {
                    Text("내 업무를 보려면 프로필과 참석자를 연결하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("내 프로필") {
                        onOpenProfile()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("home-my-work-hint-button")
                }
                .accessibilityIdentifier("home-my-work-hint")
            }

            if section.isEmpty {
                Text(showingMine ? "나에게 배정된 진행 업무가 없습니다." : "진행 중인 업무가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-work-empty")
            } else {
                ForEach(section.items) { entry in
                    HomeRowButton(identifier: "home-work-row-\(entry.id.uuidString)") {
                        onOpen(BrowserDestination(projectID: entry.projectID, pane: .workState))
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
                                if let reminder = reminders[entry.id], reminder.status == .scheduled {
                                    Text("알림 \(ReminderDateDisplay().string(from: reminder.fireAt))")
                                        .accessibilityIdentifier("home-work-reminder-\(entry.id.uuidString)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                hiddenCountLabel(
                    section.hiddenCount,
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
                        onOpen(BrowserDestination(projectID: entry.projectID, pane: .workState))
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
                        onOpen(BrowserDestination(projectID: entry.projectID, pane: .workState))
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
            // A profile that fails to load must not take the whole screen down with it: the four
            // areas are useful without one, so this degrades to the unpersonalised view.
            let profile = try? await profileRepository.profile()
            let reminders = (try? await reminderRepository.allReminders()) ?? []
            let active = reminders.filter { $0.status == .scheduled }
            loadState = .loaded(
                LoadedHome(
                    summary: HomeSummary(projects: projects, profile: profile),
                    remindersByActionItem: Dictionary(
                        uniqueKeysWithValues: active.map { ($0.actionItemID, $0) }
                    ),
                    hasEligibleReminderTask: projects
                        .flatMap(\.actionItems)
                        .contains {
                            ActionItemReminderService.eligibility(of: $0, profile: profile) == .eligible
                        }
                )
            )
        } catch {
            loadState = .failed("저장된 내용을 불러오지 못했습니다.")
        }
    }

    private func createReminderSample() async {
        guard !isCreatingReminderSample else { return }
        isCreatingReminderSample = true
        reminderSampleError = nil
        defer { isCreatingReminderSample = false }

        do {
            let result = try await ActionItemReminderSampleService(
                projectRepository: repository,
                profileRepository: profileRepository
            ).createOrReset()
            await load()
            onOpen(
                BrowserDestination(
                    projectID: result.projectID,
                    meetingID: result.meetingID,
                    actionItemID: result.actionItemID,
                    pane: .workState
                )
            )
        } catch {
            reminderSampleError = "알림 검증 샘플을 만들지 못했습니다."
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
