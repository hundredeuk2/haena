import SwiftUI

/// The accessibility identifiers one proposal card publishes.
///
/// Passed in rather than derived inside the card because two different screens render this card,
/// and the project pane and the meeting pane sit in the same `NavigationSplitView` — both can be on
/// screen at once, showing the same proposal. A shared identifier would then match two elements.
struct WorkStateProposalCardIdentifiers: Equatable {
    let card: String
    let confidence: String
    let evidence: String
    let approve: String
    let exclude: String
    let edit: String

    /// The project-wide review screen's identifiers, unchanged from before this card was extracted
    /// out of `WorkStateReviewView`.
    static func projectReview(_ proposalID: UUID) -> Self {
        let suffix = proposalID.uuidString
        return Self(
            card: "proposal-card-\(suffix)",
            confidence: "proposal-confidence-\(suffix)",
            evidence: "proposal-evidence-\(suffix)",
            approve: "approve-proposal-\(suffix)",
            exclude: "exclude-proposal-\(suffix)",
            edit: "edit-action-item-\(suffix)"
        )
    }

    /// The meeting results screen's identifiers.
    static func meetingResults(_ proposalID: UUID) -> Self {
        let suffix = proposalID.uuidString
        return Self(
            card: "meeting-result-pending-\(suffix)",
            confidence: "meeting-result-confidence-\(suffix)",
            evidence: "meeting-result-evidence-\(suffix)",
            approve: "meeting-result-approve-\(suffix)",
            exclude: "meeting-result-exclude-\(suffix)",
            edit: "meeting-result-edit-\(suffix)"
        )
    }
}

/// One AI proposal with the transcript quote behind it, and the verdicts a person can give it.
///
/// Shared by the project-wide review screen and the per-meeting results screen so the two cannot
/// present the same suggestion differently — in particular, so neither can quietly stop showing the
/// evidence. It renders and reports; every verdict is handed back to the caller, which routes it
/// through `WorkStateReviewService`.
struct WorkStateProposalCard: View {
    let proposal: WorkStateProposal
    /// Participants of the meeting the proposal came from, for naming an assignee.
    let participants: [Participant]
    /// A short status word above the card. Nil on the review screen, whose whole surface is already
    /// about unreviewed proposals; set on the results screen, where confirmed results sit beside it.
    var statusBadge: String?
    /// Where in the recording the quote came from. Nil whenever that cannot be answered
    /// truthfully — the card must never print a time it had to invent.
    var evidenceTimestamp: String?
    let identifiers: WorkStateProposalCardIdentifiers
    let onApprove: () -> Void
    let onExclude: () -> Void
    /// Nil for kinds with nothing to correct: only an action item carries an assignee and a due date.
    var onEdit: (() -> Void)?

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let statusBadge {
                    WorkStateStatusBadge(text: statusBadge, isProminent: true)
                }

                Text(WorkStateDisplay.label(for: proposal.kind))
                    .font(.caption)
                    .bold()

                Spacer()

                if let confidence = WorkStateDisplay.confidenceLabel(proposal.confidence) {
                    Text(confidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(identifiers.confidence)
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
                ActionItemMetaRow(actionItem: item, participants: participants)
            }

            // The evidence is the whole point of the review step: a user should never have to take
            // the model's word for what was said.
            if let evidence = proposal.evidence {
                WorkStateEvidenceQuote(quote: evidence.quote, timestamp: evidenceTimestamp)
                    .accessibilityIdentifier(identifiers.evidence)
            }

            HStack {
                Button("승인", action: onApprove)
                    .accessibilityIdentifier(identifiers.approve)

                Button("제외", action: onExclude)
                    .accessibilityIdentifier(identifiers.exclude)

                if let onEdit {
                    Button("수정", action: onEdit)
                        .accessibilityIdentifier(identifiers.edit)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifiers.card)
    }
}

/// A short word for where a result stands. Spelled out rather than expressed as a colour alone, so
/// it survives being read aloud, printed, or seen by someone who cannot distinguish the tint.
struct WorkStateStatusBadge: View {
    let text: String
    /// Set for the one state that is a call to action rather than a description.
    var isProminent: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private var background: AnyShapeStyle {
        isProminent ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.4))
    }
}

/// The transcript line a result was drawn from, optionally with its position in the recording.
///
/// The timestamp is omitted rather than defaulted when the transcript has none — pasted text has no
/// timing at all, and a `00:00` beside a quote from the middle of a meeting is a lie about the
/// source, on the one element that exists to let a user check the source.
struct WorkStateEvidenceQuote: View {
    let quote: String
    var timestamp: String?

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var label: String {
        guard let timestamp else {
            return "원문 “\(quote)”"
        }
        return "원문 \(timestamp) “\(quote)”"
    }
}

/// The two fields extraction most often cannot fill, plus optionally where the work stands.
struct ActionItemMetaRow: View {
    let actionItem: ActionItem
    let participants: [Participant]
    var showsStatus: Bool = false

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        HStack(spacing: 12) {
            if showsStatus {
                Text(WorkStateDisplay.label(for: actionItem.status))
            }

            Text(WorkStateDisplay.assigneeLabel(actionItem.assigneeID, participants: participants))

            if let due = WorkStateDisplay.dueDateLabel(actionItem.dueDate, formatter: dateFormatter) {
                Text(due)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
