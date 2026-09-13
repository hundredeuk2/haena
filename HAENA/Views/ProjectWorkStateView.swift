import SwiftUI

/// Approved project state retains existing edit, lifecycle and reminder services.
/// Pending candidates belong only to WorkStateReviewView.
struct ProjectWorkStateView: View {
    let project: Project
    let reviewService: WorkStateReviewService
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let reminderService: ActionItemReminderService?
    let onChanged: () async -> Void
    /// One task to bring into view, from the home's 지금 할 일 card. Scrolled to once when this pane
    /// appears and marked while it stays; the parent drops it as soon as the user moves on, so this
    /// never becomes a filter over what the screen shows.
    var selection: ProjectWorkStateSelection?
    private var highlightedActionItemID: UUID? { selection?.actionItemID }

    @State private var errorMessage: String?
    @State private var editingActionItem: ActionItem?
    @State private var reminderActionItem: ActionItem?
    @State private var profile: LocalUserProfile?
    @State private var remindersByActionItem: [UUID: ActionItemReminder] = [:]
    /// Guards the scroll against re-running when the parent reloads the project after a verdict —
    /// which would yank the user back mid-review.
    @State private var didScrollToHighlight = false

    private var dateFormatter: MeetingDateFormatter { MeetingDateFormatter(locale: AppLanguageSettings.shared.locale) }


    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selection {
                        if let selected = selection.proposal(in: project) {
                            Text(L10n.format("선택한 승인 항목: %@", selected.headline))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("approved-selected-object")
                        } else {
                            Text(L10n.text("선택한 항목은 현재 승인된 업무 상태에 없습니다."))
                                .accessibilityIdentifier("approved-selection-unavailable")
                        }
                    }
                    if let errorMessage {
                        Text(L10n.text(errorMessage))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("work-state-review-error-message")
                    }

                    reviewedSections
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollToHighlightedItem(using: proxy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approved-work-state-screen")
        .sheet(item: $editingActionItem) { item in
            ActionItemEditView(
                actionItem: item,
                participants: assignableParticipants(forMeeting: item.meetingID),
                onSave: { assigneeID, dueDate in
                    await perform {
                        try await reviewService.updateActionItem(
                            id: item.id,
                            in: project.id,
                            assigneeID: assigneeID,
                            dueDate: dueDate
                        )
                    }
                    editingActionItem = nil
                },
                onCancel: { editingActionItem = nil }
            )
        }
        .sheet(item: $reminderActionItem) { item in
            if let reminderService {
                ActionItemReminderView(
                    project: project,
                    actionItem: item,
                    service: reminderService,
                    existingReminder: remindersByActionItem[item.id],
                    onChanged: {
                        await loadReminderState()
                        await onChanged()
                    },
                    onClose: { reminderActionItem = nil }
                )
            }
        }
        .task(id: project.updatedAt) {
            await loadReminderState()
        }
    }

    // MARK: - Reviewed work state

    @ViewBuilder
    private var reviewedSections: some View {
        let decisions = WorkStateInbox.confirmedDecisions(in: project)
        let actionItems = WorkStateInbox.activeActionItems(in: project)
        let questions = WorkStateInbox.reviewedOpenQuestions(in: project)
        let agenda = WorkStateInbox.reviewedAgendaItems(in: project)

        Divider()

        section(L10n.text("결정 로그"), identifier: "decision-log-section", isEmpty: decisions.isEmpty) {
            ForEach(decisions) { decision in
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.statement)
                    if let evidence = decision.evidence {
                        Text(L10n.format("원문 “%@”", String(describing: evidence.quote)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("confirmed-decision-\(decision.id.uuidString)")
                .id(ProjectWorkStateSelection.decision(decision.id))
            }
        }

        section(L10n.text("진행 중인 업무"), identifier: "active-work-section", isEmpty: actionItems.isEmpty) {
            ForEach(actionItems) { item in
                VStack(alignment: .leading, spacing: 8) {
                    // The project browser's middle column can be narrow. Giving the title its own
                    // row prevents the action buttons from squeezing Korean text down to one
                    // character per line, which used to hide both the task and its reminder CTA.
                    Text(item.title)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.format("상태 · %@", String(describing: UIWorkStateDisplay.label(for: item.status))))
                        Text(UIWorkStateDisplay.assigneeLabel(item.assigneeID, participants: participants(forMeeting: item.meetingID)))
                        if let due = UIWorkStateDisplay.dueDateLabel(item.dueDate, formatter: dateFormatter) {
                            Text(due)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if reminderService != nil,
                       ActionItemReminderService.eligibility(of: item, profile: profile) == .eligible {
                        if item.id == highlightedActionItemID {
                            Text(L10n.text("이 업무의 알림은 아래 버튼에서 설정하세요."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("highlighted-reminder-guidance")
                        }

                        Button {
                            reminderActionItem = item
                        } label: {
                            Label(
                                remindersByActionItem[item.id]?.status == .scheduled ? L10n.text("알림 변경") : L10n.text("알림 설정"),
                                systemImage: "bell"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("action-item-reminder-\(item.id.uuidString)")
                    }

                    if let reminder = remindersByActionItem[item.id], reminder.status == .scheduled {
                        Text(L10n.format("알림 예정 · %@", ReminderDateDisplay(locale: AppLanguageSettings.shared.locale).string(from: reminder.fireAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("action-item-reminder-status-\(item.id.uuidString)")
                    }

                    // Lifecycle and editing controls stay in their own compact row. They no longer
                    // compete with the title or the primary reminder action for horizontal space.
                    HStack(spacing: 8) {
                        if item.status == .confirmed {
                            Button(L10n.text("진행 시작")) {
                                Task { await setStatus(.inProgress, for: item) }
                            }
                            .accessibilityIdentifier("start-action-item-\(item.id.uuidString)")
                        }
                        Button(L10n.text("완료")) {
                            Task { await setStatus(.completed, for: item) }
                        }
                        .accessibilityIdentifier("complete-action-item-\(item.id.uuidString)")

                        Button(L10n.text("수정")) {
                            editingActionItem = item
                        }
                        .accessibilityIdentifier("edit-action-item-\(item.id.uuidString)")

                        Spacer(minLength: 0)

                        Menu {
                            Button(L10n.text("업무 취소"), role: .destructive) {
                                Task { await setStatus(.cancelled, for: item) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(L10n.text("업무 더보기"))
                        .accessibilityIdentifier("action-item-more-\(item.id.uuidString)")
                    }
                    .controlSize(.small)
                }
                // A tint rather than a selection: it says "this is the one you came for" without
                // implying the row is now in a state the user has to get it out of.
                .padding(.vertical, item.id == highlightedActionItemID ? 4 : 0)
                .background(
                    item.id == highlightedActionItemID
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(.clear)
                )
                // The anchor `scrollToHighlightedItem` aims at.
                .id(ProjectWorkStateSelection.actionItem(item.id))
                // Keep a queryable card container without replacing the identifiers of its
                // reminder and lifecycle controls in the accessibility tree.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("active-action-item-\(item.id.uuidString)")
            }
        }

        section(L10n.text("미해결 질문"), identifier: "open-questions-section", isEmpty: questions.isEmpty) {
            ForEach(questions) { question in
                Text(question.question)
                    .accessibilityIdentifier("open-question-\(question.id.uuidString)")
                .id(ProjectWorkStateSelection.openQuestion(question.id))
            }
        }

        section(L10n.text("다음 아젠다"), identifier: "agenda-section", isEmpty: agenda.isEmpty) {
            ForEach(agenda) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("agenda-item-\(item.id.uuidString)")
                .id(ProjectWorkStateSelection.agendaItem(item.id))
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        identifier: String,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if isEmpty {
                Text(L10n.text("아직 없습니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Arriving on one task

    /// Brings the requested task into view, once.
    ///
    /// Deferred to the next run loop turn because the rows this aims at are only laid out after
    /// this appearance has finished — asking for an anchor that does not exist yet does nothing at
    /// all. Silently does nothing when the task is not on screen either, which is the right outcome
    /// for one approved or completed in another window since the home last loaded.
    private func scrollToHighlightedItem(using proxy: ScrollViewProxy) {
        guard let selection, !didScrollToHighlight else {
            return
        }
        didScrollToHighlight = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    // MARK: - Actions

    private func setStatus(_ status: ActionItemStatus, for item: ActionItem) async {
        await perform {
            try await reviewService.setActionItemStatus(status, id: item.id, in: project.id)
        }
    }

    /// One place to run a review action: clear the last error, apply it, then let the parent reload
    /// so the list reflects what is actually stored.
    private func perform(_ action: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await action()
            await reminderService?.reconcile()
            await loadReminderState()
            await onChanged()
        } catch WorkStateReviewError.unknownAssignee {
            errorMessage = "이 회의에 참석하지 않은 사람은 담당자로 지정할 수 없습니다."
        } catch {
            errorMessage = "변경 사항을 저장하지 못했습니다."
        }
    }

    private func loadReminderState() async {
        profile = try? await profileRepository.profile()
        let reminders = (try? await reminderRepository.allReminders()) ?? []
        remindersByActionItem = Dictionary(
            uniqueKeysWithValues: reminders
                .filter { $0.status == .scheduled }
                .map { ($0.actionItemID, $0) }
        )
    }

    /// Ids are preserved and only names substituted, so an assignee stored against an anonymous
    /// speaker keeps resolving and starts showing the confirmed name. Nil for an agenda item with
    /// no source meeting, which names nobody anyway.
    private func participants(forMeeting meetingID: UUID?) -> [Participant] {
        guard let meetingID else {
            return []
        }
        return project.meetings.first { $0.id == meetingID }?.displayRoster ?? []
    }

    /// Choices, so two voices confirmed as one person collapse into a single row.
    private func assignableParticipants(forMeeting meetingID: UUID) -> [Participant] {
        project.meetings.first { $0.id == meetingID }?.assignableParticipants ?? []
    }
}
