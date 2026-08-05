import Foundation

/// Renders a project's reviewed state as one Markdown document, for pasting into Notion, a
/// messenger, or an email.
///
/// Pure by construction: it reads only a `Project` and the summary derived from it — no
/// repository, no provider, no OpenAI DTO — and it takes the current time as a parameter instead
/// of reading the clock, so the same input always produces the same document.
///
/// What it leaves out carries as much weight as what it includes. An unreviewed AI proposal
/// appears only as a count, never as text: exported Markdown travels to places this app cannot
/// see or correct, and a model's guess must not arrive somewhere looking like something the team
/// agreed to. For the same reason nothing internal goes in the document — no identifiers, no file
/// paths, no provider or key configuration; only what a person approved, in the words it was
/// approved in.
struct ProjectMarkdownRenderer {
    private let dateFormatter: MeetingDateFormatter

    init(dateFormatter: MeetingDateFormatter = MeetingDateFormatter()) {
        self.dateFormatter = dateFormatter
    }

    /// `summary` should normally be `ProjectStatusSummary.complete(project:referenceDate:)` — the
    /// screen's capped summary would produce a document that silently omits items.
    func render(project: Project, summary: ProjectStatusSummary, generatedAt: Date) -> String {
        var lines: [String] = []

        lines.append("# \(project.name)")
        lines.append("")
        lines.append("- 생성 시각: \(dateFormatter.string(from: generatedAt))")
        lines.append("- 확인 필요한 AI 제안: \(summary.pendingProposalCount)건")
        lines.append("")

        lines += section("확정된 결정", blocks: summary.recentDecisions.items.map { decision in
            block(decision.statement, evidence: decision.evidence)
        })

        lines += section("진행 중인 업무", blocks: summary.activeActionItems.items.map { item in
            block(
                item.title,
                evidence: item.evidence,
                details: [
                    "담당자: \(WorkStateDisplay.assigneeName(item.assigneeID, participants: participants(of: item.meetingID, in: project)) ?? "미지정")",
                    "마감일: \(item.dueDate.map(dateFormatter.dateOnlyString(from:)) ?? "없음")",
                    "상태: \(WorkStateDisplay.label(for: item.status))",
                ]
            )
        })

        lines += section("미해결 질문", blocks: summary.unresolvedQuestions.items.map { question in
            block(question.question, evidence: question.evidence)
        })

        lines += section("다음 아젠다", blocks: summary.upcomingAgendaItems.items.map { item in
            block(
                item.title,
                evidence: item.evidence,
                details: item.reason.isEmpty ? [] : ["사유: \(item.reason)"]
            )
        })

        // Each section leaves a blank line behind it to separate it from the next; the last one has
        // nothing to separate from. Collapse to exactly one trailing newline — a text file ends
        // with one, and editors differ on what they do to a file that does not.
        let body = lines.joined(separator: "\n")
        return body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n"
    }

    // MARK: - Building blocks

    /// An empty area is written out as 없음 rather than dropped, so a reader can tell "nothing
    /// here" apart from "this export forgot a section".
    private func section(_ title: String, blocks: [[String]]) -> [String] {
        var lines = ["## \(title)", ""]
        if blocks.isEmpty {
            lines.append("없음")
        } else {
            lines += blocks.flatMap { $0 }
        }
        lines.append("")
        return lines
    }

    private func block(_ headline: String, evidence: EvidenceReference?, details: [String] = []) -> [String] {
        var lines = ["- \(headline)"]
        lines += details.map { "  - \($0)" }
        if let quote = evidence?.quote {
            lines += quoteLines(quote)
        }
        return lines
    }

    /// The quote is reproduced exactly as it was said — never trimmed, translated, or reworded,
    /// because its only value is being checkable against the transcript. A quote spanning several
    /// lines needs the marker repeated on each one, or the rest of the document falls out of the
    /// blockquote; the two-space indent keeps it inside the bullet it belongs to.
    private func quoteLines(_ quote: String) -> [String] {
        quote.components(separatedBy: .newlines).map { "  > \($0)" }
    }

    private func participants(of meetingID: UUID, in project: Project) -> [Participant] {
        project.meetings.first { $0.id == meetingID }?.participants ?? []
    }
}
