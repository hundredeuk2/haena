import SwiftUI

/// Pending-only inbox. ProjectWorkStateView owns approved work and lifecycle controls.
/// The repository is reloaded after explicit single-item service calls; no optimistic verdict.
struct WorkStateReviewView: View {
    let project: Project
    let reviewService: WorkStateReviewService
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let reminderService: ActionItemReminderService?
    let onChanged: () async -> Void
    /// Opens the exact stored segment in its owning meeting's transcript. Called only with a
    /// selection `ReviewQueue` proved; the screen itself performs no navigation.
    var onOpenEvidence: ((TranscriptEvidenceSelection) -> Void)?
    @State private var filter = ReviewQueueFilter.all
    @State private var errorMessage: String?
    @State private var editingActionItem: ActionItem?
    @State private var isApplying = false
    private var queue: ReviewQueue { ReviewQueue(project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("AI 제안 %@건", String(queue.pendingCount)))
                .font(.headline).accessibilityIdentifier("pending-proposal-count")
            Text(L10n.text("승인하기 전까지는 제안 상태로만 저장됩니다."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review-approval-boundary")
            Picker(L10n.text("제안 종류"), selection: $filter) {
                ForEach(ReviewQueueFilter.allCases) { value in
                    Text(L10n.text(value.localizationKey)).tag(value)
                        .accessibilityIdentifier("review-filter-\(value.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("review-filter-picker")
            Text(L10n.format("표시 %@ / 미검토 전체 %@", String(queue.count(filter)), String(queue.pendingCount)))
                .font(.caption).accessibilityIdentifier("review-visible-count")
            if let errorMessage {
                Text(L10n.text(errorMessage)).foregroundStyle(.red)
                    .accessibilityIdentifier("work-state-review-error-message")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if queue.pendingCount == 0 {
                        Text(L10n.text("검토할 AI 제안이 없습니다."))
                            .accessibilityIdentifier("no-pending-proposals")
                    } else if queue.count(filter) == 0 {
                        Text(L10n.text("이 종류의 미검토 제안이 없습니다."))
                            .accessibilityIdentifier("no-filtered-proposals")
                    }
                    ForEach(queue.groups) { group in
                        let visible = group.visible(filter)
                        if !visible.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.meeting?.title ?? L10n.text(group.id == nil
                                    ? "소유 회의가 지정되지 않았습니다." : "소유 회의를 찾을 수 없습니다."))
                                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(L10n.format("이 회의 표시 %@ / 미검토 전체 %@", String(visible.count), String(group.pendingCount)))
                                    .font(.caption)
                                    .accessibilityIdentifier("review-group-count-\(group.id?.uuidString ?? "unassigned")")
                                ForEach(visible) { entry in
                                    WorkStateProposalCard(
                                        proposal: entry.proposal,
                                        participants: group.meeting?.displayRoster ?? [],
                                        statusBadge: L10n.text("미승인 후보"),
                                        evidenceTimestamp: entry.timestamp,
                                        sourceIssue: entry.sourceIssue,
                                        identifiers: .projectReview(entry.proposal.id),
                                        onApprove: { Task { await verdict(entry.proposal, approve: true) } },
                                        onExclude: { Task { await verdict(entry.proposal, approve: false) } },
                                        onEdit: editAction(entry.proposal),
                                        onOpenEvidence: openEvidenceAction(entry)
                                    )
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("review-group-\(group.id?.uuidString ?? "unassigned")")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .disabled(isApplying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-state-review-screen")
        .sheet(item: $editingActionItem) { item in
            ActionItemEditView(actionItem: item,
                participants: project.meetings.first { $0.id == item.meetingID }?.assignableParticipants ?? [],
                onSave: { assigneeID, dueDate in
                    let saved = await perform {
                        try await reviewService.updateActionItem(id: item.id, in: project.id,
                                                                 assigneeID: assigneeID, dueDate: dueDate)
                    }
                    if saved { editingActionItem = nil }
                }, onCancel: { editingActionItem = nil })
        }
    }

    private func openEvidenceAction(_ entry: ReviewQueue.Entry) -> (() -> Void)? {
        guard let onOpenEvidence, let selection = entry.transcriptSelection else { return nil }
        return { onOpenEvidence(selection) }
    }

    private func editAction(_ proposal: WorkStateProposal) -> (() -> Void)? {
        guard case .actionItem(let item) = proposal else { return nil }
        return { editingActionItem = item }
    }

    private func verdict(_ proposal: WorkStateProposal, approve: Bool) async {
        _ = await perform {
            switch proposal {
            case .decision(let item):
                if approve { try await reviewService.approveDecision(id: item.id, in: project.id) }
                else { try await reviewService.rejectDecision(id: item.id, in: project.id) }
            case .actionItem(let item):
                if approve { try await reviewService.approveActionItem(id: item.id, in: project.id) }
                else { try await reviewService.excludeActionItem(id: item.id, in: project.id) }
            case .openQuestion(let item):
                if approve { try await reviewService.approveOpenQuestion(id: item.id, in: project.id) }
                else { try await reviewService.dismissOpenQuestion(id: item.id, in: project.id) }
            case .agendaItem(let item):
                if approve { try await reviewService.approveAgendaItem(id: item.id, in: project.id) }
                else { try await reviewService.dismissAgendaItem(id: item.id, in: project.id) }
            }
        }
    }

    private func perform(_ action: () async throws -> Void) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        defer { isApplying = false }
        errorMessage = nil
        do {
            try await action()
            await reminderService?.reconcile()
            await onChanged()
            return true
        } catch WorkStateReviewError.unknownAssignee {
            errorMessage = "이 회의에 참석하지 않은 사람은 담당자로 지정할 수 없습니다."
        } catch {
            errorMessage = "변경 사항을 저장하지 못했습니다."
        }
        return false
    }
}
