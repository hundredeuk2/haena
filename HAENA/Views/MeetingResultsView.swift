import SwiftUI

/// What one meeting turned into: its decisions, its work, the questions it left open, and what it
/// pushed to the next agenda — four areas on one surface, so selecting a meeting answers "what came
/// of this" before it answers "what was said".
///
/// Purely a renderer for `MeetingWorkStateSummary`. It holds no attribution, classification or
/// ordering rules of its own, and it writes nothing: every verdict goes through
/// `WorkStateReviewService`, after which the parent reloads, so what is shown always comes from
/// stored data rather than from optimistic local edits.
struct MeetingResultsView: View {
    let project: Project
    let meeting: Meeting
    let reviewService: WorkStateReviewService
    let onChanged: () async -> Void

    @State private var errorMessage: String?
    @State private var editingActionItem: ActionItem?
    /// Which 처리됨 groups the user has opened, keyed by section. Collapsed by default: closed-out
    /// results are kept so they can be found, not so they compete with live ones.
    @State private var expandedProcessedSections: Set<String> = []

    private let dateFormatter = MeetingDateFormatter()

    private var summary: MeetingWorkStateSummary {
        MeetingWorkStateSummary(project: project, meetingID: meeting.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("meeting-results-error-message")
                }

                decisionSection
                actionItemSection
                openQuestionSection
                agendaSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No preferred height of its own — it takes whatever height it is handed and scrolls inside
        // it. `idealHeight: 0` is the load-bearing part: a bare `ScrollView` reports the full height
        // of its content as the height it would like, and this pane sits inside a window-sized
        // sheet that lays its content out at that requested height and then centres it. A meeting
        // with enough results pushed the request past the sheet, and everything above this screen —
        // the meeting title, the tab picker, 회의 삭제 — was centred off the top edge.
        .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-results-screen")
        .sheet(item: $editingActionItem) { item in
            ActionItemEditView(
                actionItem: item,
                participants: meeting.assignableParticipants,
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

    // MARK: - Sections

    private var decisionSection: some View {
        resultSection(
            title: "결정 사항",
            identifier: "meeting-result-decision-section",
            area: summary.decisions,
            emptyMessage: "아직 확인된 결정 사항이 없습니다."
        ) { decision in
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.statement)
                    .fixedSize(horizontal: false, vertical: true)
                evidenceQuote(decision.evidence)
                WorkStateStatusBadge(text: WorkStateDisplay.label(for: decision.status))
            }
        }
    }

    private var actionItemSection: some View {
        resultSection(
            title: "실행 항목",
            identifier: "meeting-result-action-item-section",
            area: summary.actionItems,
            emptyMessage: "아직 확인된 실행 항목이 없습니다."
        ) { item in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button("수정") {
                        editingActionItem = item
                    }
                    .accessibilityIdentifier("meeting-result-edit-\(item.id.uuidString)")
                }

                ActionItemMetaRow(
                    actionItem: item,
                    participants: meeting.displayRoster,
                    showsStatus: true
                )

                evidenceQuote(item.evidence)
            }
        }
    }

    private var openQuestionSection: some View {
        resultSection(
            title: "미해결 질문",
            identifier: "meeting-result-open-question-section",
            area: summary.openQuestions,
            emptyMessage: "아직 확인된 미해결 질문이 없습니다."
        ) { question in
            VStack(alignment: .leading, spacing: 4) {
                Text(question.question)
                    .fixedSize(horizontal: false, vertical: true)
                evidenceQuote(question.evidence)
                WorkStateStatusBadge(text: WorkStateDisplay.label(for: question.status))
            }
        }
    }

    private var agendaSection: some View {
        resultSection(
            title: "다음 아젠다",
            identifier: "meeting-result-next-agenda-section",
            area: summary.agendaItems,
            emptyMessage: "아직 확인된 다음 아젠다가 없습니다."
        ) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                evidenceQuote(item.evidence)
                WorkStateStatusBadge(text: WorkStateDisplay.label(for: item.status))
            }
        }
    }

    // MARK: - Section shell

    /// One area: the proposals waiting on the user, the results that are live, and a collapsed
    /// group for what has been closed out.
    ///
    /// An empty area still renders its heading rather than disappearing. A user has to learn which
    /// four things a meeting produces, and a section that vanishes when it is empty teaches the
    /// opposite — that the app sometimes just does not look for them.
    @ViewBuilder
    private func resultSection<Item: Identifiable & Equatable & Sendable, Row: View>(
        title: String,
        identifier: String,
        area: MeetingResultArea<Item>,
        emptyMessage: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View where Item.ID == UUID {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)

                Text("\(area.activeCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-count")

                Spacer()
            }

            if area.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-empty")
            }

            ForEach(area.needsReview) { proposal in
                WorkStateProposalCard(
                    proposal: proposal,
                    participants: meeting.displayRoster,
                    statusBadge: "확인 필요",
                    evidenceTimestamp: MeetingWorkStateSummary.evidenceTimestamp(
                        proposal.evidence,
                        in: meeting
                    ),
                    identifiers: .meetingResults(proposal.id),
                    onApprove: { Task { await approve(proposal) } },
                    onExclude: { Task { await exclude(proposal) } },
                    onEdit: editAction(for: proposal)
                )
            }

            ForEach(area.reviewed) { item in
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("meeting-result-reviewed-\(item.id.uuidString)")
            }

            if !area.processed.isEmpty {
                DisclosureGroup(isExpanded: isProcessedExpanded(identifier)) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(area.processed) { item in
                            row(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("meeting-result-processed-\(item.id.uuidString)")
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("처리됨 \(area.processed.count)건")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("\(identifier)-processed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func isProcessedExpanded(_ identifier: String) -> Binding<Bool> {
        Binding(
            get: { expandedProcessedSections.contains(identifier) },
            set: { isExpanded in
                if isExpanded {
                    expandedProcessedSections.insert(identifier)
                } else {
                    expandedProcessedSections.remove(identifier)
                }
            }
        )
    }

    /// Shown beside a result only when the transcript really carries a position for its quote.
    @ViewBuilder
    private func evidenceQuote(_ evidence: EvidenceReference?) -> some View {
        if let evidence {
            WorkStateEvidenceQuote(
                quote: evidence.quote,
                timestamp: MeetingWorkStateSummary.evidenceTimestamp(evidence, in: meeting)
            )
        }
    }

    // MARK: - Actions

    private func editAction(for proposal: WorkStateProposal) -> (() -> Void)? {
        guard case .actionItem(let item) = proposal else {
            return nil
        }
        return { editingActionItem = item }
    }

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
    /// so the four areas reflect what is actually stored.
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
}
