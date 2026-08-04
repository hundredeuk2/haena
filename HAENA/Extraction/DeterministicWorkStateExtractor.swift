import Foundation

/// A `WorkStateExtractor` that calls nothing and always returns the same shape of result for the
/// same input, so unit and UI tests can exercise the extraction flow without a network or an API
/// key.
///
/// This is wired in **only** at the app's assembly point when launched under UI test, and is never
/// substituted for a real provider when one fails — a user must never be shown invented work
/// state because an API call errored.
struct DeterministicWorkStateExtractor: WorkStateExtractor {
    let modelID: String
    let now: @Sendable () -> Date

    init(modelID: String = "deterministic-v1", now: @escaping @Sendable () -> Date = Date.init) {
        self.modelID = modelID
        self.now = now
    }

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        let metadata = ModelRunMetadata(provider: .deterministic, modelID: modelID, completedAt: now())

        guard let excerpt = input.excerpts.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return WorkStateExtractionResult(metadata: metadata)
        }

        // A prefix of the stored text, so the quote is a verbatim substring by construction and
        // passes the same evidence validation a real provider's output has to pass.
        let evidence = ProposedEvidence(
            segmentID: excerpt.segmentID.uuidString,
            quote: Self.leadingQuote(from: excerpt.text)
        )

        return WorkStateExtractionResult(
            decisions: [
                ProposedDecision(
                    statement: "회의록 기반 결정 제안",
                    rationale: nil,
                    confidence: 0.5,
                    evidence: evidence
                )
            ],
            actionItems: [
                ProposedActionItem(
                    title: "회의록 기반 업무 제안",
                    details: nil,
                    assigneeName: nil,
                    dueDate: nil,
                    confidence: 0.5,
                    evidence: evidence
                )
            ],
            openQuestions: [
                ProposedOpenQuestion(
                    question: "회의록 기반 미해결 질문 제안",
                    confidence: 0.5,
                    evidence: evidence
                )
            ],
            nextAgendaItems: [
                ProposedAgendaItem(
                    title: "다음 회의 아젠다 제안",
                    reason: "이전 회의 내용 후속 확인",
                    confidence: 0.5,
                    evidence: evidence
                )
            ],
            metadata: metadata
        )
    }

    /// First line (or first 80 characters, whichever is shorter) of the segment. Trimming only
    /// removes characters from the ends, so the result stays a contiguous substring of `text`.
    private static func leadingQuote(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(firstLine.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}
