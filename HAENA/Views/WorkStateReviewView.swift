import SwiftUI

/// The review half of the trust loop: everything the model proposed for this project, with the
/// transcript quote behind it, waiting for a person to approve or exclude it — and below that, the
/// work state that has already been through review.
///
/// Nothing here writes to the repository directly; every verdict goes through
/// `WorkStateReviewService`, and the parent reloads afterwards so what is shown always comes from
/// stored data rather than from optimistic local edits.
struct WorkStateReviewView: View {
    let project: Project
    let reviewService: WorkStateReviewService
    let onChanged: () async -> Void
    /// One task to bring into view, from the home's 지금 할 일 card. Scrolled to once when this pane
    /// appears and marked while it stays; the parent drops it as soon as the user moves on, so this
    /// never becomes a filter over what the screen shows.
    var highlightedActionItemID: UUID?

    @State private var errorMessage: String?
    @State private var editingActionItem: ActionItem?
    /// Guards the scroll against re-running when the parent reloads the project after a verdict —
    /// which would yank the user back mid-review.
    @State private var didScrollToHighlight = false

    private let dateFormatter = MeetingDateFormatter()

    private var proposals: [WorkStateProposal] {
        WorkStateInbox.pendingProposals(in: project)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("work-state-review-error-message")
                    }

                    proposalsSection
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
        .accessibilityIdentifier("work-state-review-screen")
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
    }

    // MARK: - Pending proposals

    @ViewBuilder
    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 제안 \(proposals.count)건")
                .font(.headline)
                .accessibilityIdentifier("pending-proposal-count")

            if proposals.isEmpty {
                Text("검토할 AI 제안이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("no-pending-proposals")
            } else {
                Text("승인하기 전까지는 제안 상태로만 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(proposals) { proposal in
                    proposalCard(proposal)
                }
            }
        }
    }

    /// Rendered by the shared `WorkStateProposalCard`, which the per-meeting results screen uses
    /// too: one card means neither screen can drift into showing a proposal without its evidence,
    /// or offering a verdict the other does not.
    private func proposalCard(_ proposal: WorkStateProposal) -> some View {
        WorkStateProposalCard(
            proposal: proposal,
            participants: participants(forMeeting: proposal.meetingID),
            identifiers: .projectReview(proposal.id),
            onApprove: { Task { await approve(proposal) } },
            onExclude: { Task { await exclude(proposal) } },
            onEdit: editAction(for: proposal)
        )
    }

    /// Only an action item has fields worth correcting, so every other kind gets no 수정 button.
    private func editAction(for proposal: WorkStateProposal) -> (() -> Void)? {
        guard case .actionItem(let item) = proposal else {
            return nil
        }
        return { editingActionItem = item }
    }

    // MARK: - Reviewed work state

    @ViewBuilder
    private var reviewedSections: some View {
        let decisions = WorkStateInbox.confirmedDecisions(in: project)
        let actionItems = WorkStateInbox.activeActionItems(in: project)
        let questions = WorkStateInbox.reviewedOpenQuestions(in: project)
        let agenda = WorkStateInbox.reviewedAgendaItems(in: project)

        Divider()

        section("결정 로그", identifier: "decision-log-section", isEmpty: decisions.isEmpty) {
            ForEach(decisions) { decision in
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.statement)
                    if let evidence = decision.evidence {
                        Text("원문 “\(evidence.quote)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("confirmed-decision-\(decision.id.uuidString)")
            }
        }

        section("진행 중인 업무", identifier: "active-work-section", isEmpty: actionItems.isEmpty) {
            ForEach(actionItems) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.title)
                        Spacer()
                        Button("수정") {
                            editingActionItem = item
                        }
                        .accessibilityIdentifier("edit-action-item-\(item.id.uuidString)")
                    }
                    HStack(spacing: 12) {
                        Text(WorkStateDisplay.label(for: item.status))
                        Text(WorkStateDisplay.assigneeLabel(item.assigneeID, participants: participants(forMeeting: item.meetingID)))
                        if let due = WorkStateDisplay.dueDateLabel(item.dueDate, formatter: dateFormatter) {
                            Text(due)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .id(item.id)
                .accessibilityIdentifier("active-action-item-\(item.id.uuidString)")
            }
        }

        section("미해결 질문", identifier: "open-questions-section", isEmpty: questions.isEmpty) {
            ForEach(questions) { question in
                Text(question.question)
                    .accessibilityIdentifier("open-question-\(question.id.uuidString)")
            }
        }

        section("다음 아젠다", identifier: "agenda-section", isEmpty: agenda.isEmpty) {
            ForEach(agenda) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("agenda-item-\(item.id.uuidString)")
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
                Text("아직 없습니다.")
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
        guard let highlightedActionItemID, !didScrollToHighlight else {
            return
        }
        didScrollToHighlight = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(highlightedActionItemID, anchor: .center)
            }
        }
    }

    // MARK: - Actions

    private func approve(_ proposal: WorkStateProposal) async {
        await perform {
            switch proposal {
            case .decision(let decision):
                try await reviewService.approveDecision(id: decision.id, in: project.id)
            case .actionItem(let item):
                try await reviewService.approveActionItem(id: item.id, in: project.id)
            case .openQuestion(let question):
                try await reviewService.approveOpenQuestion(id: question.id, in: project.id)
            case .agendaItem(let item):
                try await reviewService.approveAgendaItem(id: item.id, in: project.id)
            }
        }
    }

    private func exclude(_ proposal: WorkStateProposal) async {
        await perform {
            switch proposal {
            case .decision(let decision):
                try await reviewService.rejectDecision(id: decision.id, in: project.id)
            case .actionItem(let item):
                try await reviewService.excludeActionItem(id: item.id, in: project.id)
            case .openQuestion(let question):
                try await reviewService.dismissOpenQuestion(id: question.id, in: project.id)
            case .agendaItem(let item):
                try await reviewService.dismissAgendaItem(id: item.id, in: project.id)
            }
        }
    }

    /// One place to run a review action: clear the last error, apply it, then let the parent reload
    /// so the list reflects what is actually stored.
    private func perform(_ action: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await action()
            await onChanged()
        } catch WorkStateReviewError.unknownAssignee {
            errorMessage = "이 회의에 참석하지 않은 사람은 담당자로 지정할 수 없습니다."
        } catch {
            errorMessage = "변경 사항을 저장하지 못했습니다."
        }
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
