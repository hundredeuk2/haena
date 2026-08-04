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

    @State private var errorMessage: String?
    @State private var editingActionItem: ActionItem?

    private let dateFormatter = MeetingDateFormatter()

    private var proposals: [WorkStateProposal] {
        WorkStateInbox.pendingProposals(in: project)
    }

    var body: some View {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-state-review-screen")
        .sheet(item: $editingActionItem) { item in
            ActionItemEditView(
                actionItem: item,
                participants: participants(forMeeting: item.meetingID),
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

    private func proposalCard(_ proposal: WorkStateProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(WorkStateDisplay.label(for: proposal.kind))
                    .font(.caption)
                    .bold()
                Spacer()
                if let confidence = WorkStateDisplay.confidenceLabel(proposal.confidence) {
                    Text(confidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("proposal-confidence-\(proposal.id.uuidString)")
                }
            }

            Text(proposal.headline)
                .font(.body)

            if let supporting = proposal.supporting {
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .actionItem(let item) = proposal {
                HStack(spacing: 12) {
                    Text(WorkStateDisplay.assigneeLabel(item.assigneeID, participants: participants(forMeeting: item.meetingID)))
                    if let due = WorkStateDisplay.dueDateLabel(item.dueDate, formatter: dateFormatter) {
                        Text(due)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // The evidence is the whole point of the review step: a user should never have to take
            // the model's word for what was said.
            if let evidence = proposal.evidence {
                Text("원문 “\(evidence.quote)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("proposal-evidence-\(proposal.id.uuidString)")
            }

            HStack {
                Button("승인") {
                    Task { await approve(proposal) }
                }
                .accessibilityIdentifier("approve-proposal-\(proposal.id.uuidString)")

                Button("제외") {
                    Task { await exclude(proposal) }
                }
                .accessibilityIdentifier("exclude-proposal-\(proposal.id.uuidString)")

                if case .actionItem(let item) = proposal {
                    Button("수정") {
                        editingActionItem = item
                    }
                    .accessibilityIdentifier("edit-action-item-\(item.id.uuidString)")
                }

                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proposal-card-\(proposal.id.uuidString)")
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

    private func participants(forMeeting meetingID: UUID) -> [Participant] {
        project.meetings.first { $0.id == meetingID }?.participants ?? []
    }
}
