import SwiftUI

/// The 현재 상태 screen: what has been decided, what is being worked on, what is blocked, and what
/// comes up next — all on one surface, so a user landing on a project does not have to walk three
/// other screens to reconstruct it.
///
/// Purely a renderer for `ProjectStatusSummary`. It holds no filtering or ordering rules, and it
/// duplicates neither the review screen nor the meeting list: every "전체 보기" hands off to the
/// existing 업무 상태 screen through the pane binding it shares with `ProjectDetailView`.
struct ProjectStatusView: View {
    let summary: ProjectStatusSummary
    let participantsByMeeting: (UUID) -> [Participant]
    /// Switches the surrounding segmented control over to the review screen. The summary never
    /// shows evidence or confidence itself — that detail stays on the screen built to weigh it.
    let onOpenWorkState: () -> Void
    /// Renders the export. A closure rather than a string so the document is built at the moment a
    /// user asks for it — and so both actions below are physically incapable of producing
    /// different text.
    let makeMarkdown: () -> String
    let exportFilename: String
    let pasteboardWriter: any PasteboardWriter
    let fileExporter: any MarkdownFileExporter

    @State private var feedback: Feedback?

    private let dateFormatter = MeetingDateFormatter()

    private struct Feedback: Equatable {
        let message: String
        let isError: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                exportBar
                reviewCallout
                decisionsSection
                workSection
                questionsSection
                agendaSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-status-screen")
    }

    // MARK: - Export actions

    private var exportBar: some View {
        HStack(spacing: 12) {
            Button("Markdown 내보내기") {
                exportToFile()
            }
            .accessibilityIdentifier("export-markdown-button")

            Button("클립보드 복사") {
                copyToClipboard()
            }
            .accessibilityIdentifier("copy-markdown-button")

            if let feedback {
                Text(feedback.message)
                    .font(.callout)
                    .foregroundStyle(feedback.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("export-feedback-message")
            }

            Spacer()
        }
    }

    private func exportToFile() {
        switch fileExporter.export(makeMarkdown(), suggestedFilename: exportFilename) {
        case .saved:
            show(Feedback(message: "저장됨", isError: false))
        case .cancelled:
            // Nothing to say: the user closed the panel on purpose.
            break
        case .failed:
            show(Feedback(message: "파일을 저장하지 못했습니다.", isError: true))
        }
    }

    private func copyToClipboard() {
        if pasteboardWriter.write(makeMarkdown()) {
            show(Feedback(message: "복사됨", isError: false))
        } else {
            show(Feedback(message: "클립보드에 복사하지 못했습니다.", isError: true))
        }
    }

    /// Clears itself so the confirmation reads as being about the action just taken, rather than
    /// lingering next to a button the user might press again.
    private func show(_ newFeedback: Feedback) {
        feedback = newFeedback
        Task {
            try? await Task.sleep(for: .seconds(2))
            if feedback == newFeedback {
                feedback = nil
            }
        }
    }


    // MARK: - Needs review

    /// Kept visually apart from every section below it, because an unreviewed proposal is the one
    /// thing on this screen that is not yet part of the project's state.
    @ViewBuilder
    private var reviewCallout: some View {
        if summary.pendingProposalCount == 0 {
            HStack(spacing: 8) {
                Text("확인 필요")
                    .font(.headline)
                Text("검토할 AI 제안이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("status-review-callout-empty")
        } else {
            Button(action: onOpenWorkState) {
                HStack(spacing: 8) {
                    Text("확인 필요")
                        .font(.headline)
                    Text("검토를 기다리는 AI 제안 \(summary.pendingProposalCount)건")
                        .font(.callout)
                    Spacer()
                    Text("검토하기")
                        .font(.callout)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status-review-callout")
        }
    }

    // MARK: - Sections

    private var decisionsSection: some View {
        summarySection(
            title: "최근 확정 결정",
            identifier: "status-decisions-section",
            section: summary.recentDecisions,
            emptyMessage: "확정된 결정이 아직 없습니다."
        ) { decision in
            Text(decision.statement)
                .lineLimit(2)
                .accessibilityIdentifier("status-decision-\(decision.id.uuidString)")
        }
    }

    private var workSection: some View {
        summarySection(
            title: "진행 업무",
            identifier: "status-work-section",
            section: summary.activeActionItems,
            emptyMessage: "진행 중인 업무가 없습니다."
        ) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Text(WorkStateDisplay.assigneeLabel(item.assigneeID, participants: participantsByMeeting(item.meetingID)))

                    if let due = WorkStateDisplay.dueDateLabel(item.dueDate, formatter: dateFormatter) {
                        // Spelled out as well as tinted: a colour alone would not survive being
                        // read aloud, printed, or seen by a user who cannot distinguish it.
                        Text(summary.isOverdue(item) ? "\(due) · 지남" : due)
                            .foregroundStyle(summary.isOverdue(item) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .accessibilityIdentifier("status-work-due-\(item.id.uuidString)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("status-work-\(item.id.uuidString)")
        }
    }

    private var questionsSection: some View {
        summarySection(
            title: "미해결 질문",
            identifier: "status-questions-section",
            section: summary.unresolvedQuestions,
            emptyMessage: "미해결 질문이 없습니다."
        ) { question in
            Text(question.question)
                .lineLimit(2)
                .accessibilityIdentifier("status-question-\(question.id.uuidString)")
        }
    }

    private var agendaSection: some View {
        summarySection(
            title: "다음 아젠다",
            identifier: "status-agenda-section",
            section: summary.upcomingAgendaItems,
            emptyMessage: "다음 아젠다가 없습니다."
        ) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityIdentifier("status-agenda-\(item.id.uuidString)")
        }
    }

    // MARK: - Section shell

    @ViewBuilder
    private func summarySection<Item: Equatable & Sendable & Identifiable, Row: View>(
        title: String,
        identifier: String,
        section: ProjectStatusSection<Item>,
        emptyMessage: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)

                Text("\(section.totalCount)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-count")

                Spacer()

                if !section.isEmpty {
                    Button("전체 보기", action: onOpenWorkState)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("\(identifier)-see-all")
                }
            }

            if section.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-empty")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items) { item in
                        row(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if section.hiddenCount > 0 {
                        Text("외 \(section.hiddenCount)건")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("\(identifier)-more")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
