import Foundation

/// Why a proposal was thrown away instead of stored. Kept as data (not just a log line) so a
/// caller can report "the model returned 6 items, 2 could not be grounded in the transcript"
/// without re-running the extraction.
struct RejectedProposal: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case decision
        case actionItem
        case openQuestion
        case agendaItem
    }

    enum Reason: String, Equatable, Sendable {
        /// `segmentID` was malformed, or named a segment that is not part of this meeting.
        case unknownSegment
        /// The quote is not a verbatim substring of the cited segment's text.
        case quoteNotInTranscript
        case confidenceOutOfRange
        case emptyContent
    }

    let kind: Kind
    let reason: Reason
}

/// The result of validating one extractor run: domain models ready to store, plus the proposals
/// that failed validation. Both halves matter — a partially wrong model response must still yield
/// its verifiable items.
struct ValidatedWorkState: Equatable, Sendable {
    var decisions: [Decision] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [OpenQuestion] = []
    var agendaItems: [AgendaItem] = []
    var rejected: [RejectedProposal] = []

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && agendaItems.isEmpty
    }
}

/// Turns a provider's raw proposals into HAE.NA domain models, rejecting anything it cannot
/// ground in the stored transcript.
///
/// Three rules drive everything here:
/// 1. **Identity is ours.** Any ID a model returns is ignored; every stored object gets an
///    app-generated `UUID`. A model must not be able to overwrite an existing record by echoing
///    its ID back.
/// 2. **Evidence is verified, never repaired.** A quote must appear verbatim in the cited
///    segment. Items that fail are dropped and reported — never "fixed up" to fit.
/// 3. **Nothing is guessed.** An assignee resolves only on an unambiguous participant match; an
///    absent or unparseable due date stays nil rather than becoming an invented date.
enum WorkStateProposalMapper {
    static func map(
        _ result: WorkStateExtractionResult,
        meeting: Meeting,
        now: Date,
        makeID: () -> UUID
    ) -> ValidatedWorkState {
        var state = ValidatedWorkState()

        for proposal in result.decisions {
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.statement, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .decision, reason: reason))
            case .grounded(let grounded):
                state.decisions.append(
                    Decision(
                        id: makeID(),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        statement: proposal.statement.trimmed,
                        rationale: proposal.rationale?.trimmedNonEmpty,
                        status: .proposed,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }

        for proposal in result.actionItems {
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.title, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .actionItem, reason: reason))
            case .grounded(let grounded):
                state.actionItems.append(
                    ActionItem(
                        id: makeID(),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        title: proposal.title.trimmed,
                        details: proposal.details?.trimmedNonEmpty,
                        assigneeID: assigneeID(matching: proposal.assigneeName, in: meeting),
                        dueDate: proposal.dueDate,
                        status: .proposed,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }

        for proposal in result.openQuestions {
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.question, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .openQuestion, reason: reason))
            case .grounded(let grounded):
                // `OpenQuestion` has no `.proposed` case — `.open` is its un-acted-on state, and
                // the accompanying evidence marks it as AI-derived rather than user-entered.
                state.openQuestions.append(
                    OpenQuestion(
                        id: makeID(),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        question: proposal.question.trimmed,
                        status: .open,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        createdAt: now,
                        resolvedAt: nil
                    )
                )
            }
        }

        for proposal in result.nextAgendaItems {
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.title, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .agendaItem, reason: reason))
            case .grounded(let grounded):
                state.agendaItems.append(
                    AgendaItem(
                        id: makeID(),
                        projectID: meeting.projectID,
                        title: proposal.title.trimmed,
                        reason: proposal.reason.trimmed,
                        sourceMeetingID: meeting.id,
                        relatedActionItemID: nil,
                        relatedOpenQuestionID: nil,
                        status: .pending,
                        createdAt: now,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence
                    )
                )
            }
        }

        return state
    }

    // MARK: - Validation

    private struct GroundedProposal {
        let evidence: EvidenceReference
        let confidence: Confidence
    }

    /// A hand-rolled two-case result rather than `Result`, whose `Failure` would have to conform
    /// to `Error` — a rejection reason is data for a report, not a thrown error.
    private enum ValidationOutcome {
        case grounded(GroundedProposal)
        case rejected(RejectedProposal.Reason)
    }

    private static func validate(
        _ evidence: ProposedEvidence,
        confidence: Double,
        content: String,
        in meeting: Meeting
    ) -> ValidationOutcome {
        guard !content.trimmed.isEmpty else {
            return .rejected(.emptyContent)
        }

        // Checked rather than clamped: a score outside [0, 1] means the response did not follow
        // the requested schema, which is a reason to distrust the whole item — not to silently
        // round it into range.
        guard confidence.isFinite, confidence >= 0, confidence <= 1 else {
            return .rejected(.confidenceOutOfRange)
        }

        guard let segmentID = UUID(uuidString: evidence.segmentID),
              let segment = meeting.transcriptSegments.first(where: { $0.id == segmentID }) else {
            return .rejected(.unknownSegment)
        }

        // Only surrounding whitespace is forgiven. Anything else — a paraphrase, a translation,
        // re-punctuation — fails: repairing a quote would fabricate the evidence it claims.
        let quote = evidence.quote.trimmed
        guard !quote.isEmpty, segment.text.contains(quote) else {
            return .rejected(.quoteNotInTranscript)
        }

        return .grounded(
            GroundedProposal(
                evidence: EvidenceReference(
                    meetingID: meeting.id,
                    transcriptSegmentID: segment.id,
                    quote: quote
                ),
                confidence: Confidence(confidence)
            )
        )
    }

    /// Resolves a spoken name to a participant only when exactly one participant matches. Zero
    /// matches or an ambiguous match both leave the action item unassigned, which is the honest
    /// answer — the alternative is inventing an owner for someone's work.
    private static func assigneeID(matching name: String?, in meeting: Meeting) -> UUID? {
        guard let name = name?.trimmedNonEmpty else {
            return nil
        }

        let matches = meeting.participants.filter { participant in
            matchesName(participant.displayName, name) || matchesName(participant.speakerLabel, name)
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func matchesName(_ candidate: String?, _ name: String) -> Bool {
        guard let candidate = candidate?.trimmedNonEmpty else {
            return false
        }
        return candidate.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
