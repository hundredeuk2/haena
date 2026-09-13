import SwiftUI

/// The accessibility identifiers one completion screen publishes.
///
/// Injected rather than fixed so the screen can take over from each capture path without renaming
/// the two controls that path already published — the saved-message line and the close button.
struct CaptureCompletionIdentifiers: Equatable {
    let savedMessage: String
    let closeButton: String

    static let pastedText = Self(
        savedMessage: "text-meeting-saved-message",
        closeButton: "cancel-text-meeting-button"
    )

    static let audio = Self(
        savedMessage: "audio-import-completed-message",
        closeButton: "cancel-audio-import-button"
    )
}

/// What a finished capture leads to: the meeting that was created, how many results of each kind
/// came out of it, and a way straight into them.
///
/// Shared by all three capture paths so that finishing a recording, an imported file and a pasted
/// transcript end the same way. It reports only — every number comes from `CaptureOutcome`, which
/// read them back from storage, and neither button changes anything.
struct CaptureCompletionView: View {
    let outcome: CaptureOutcome
    var identifiers: CaptureCompletionIdentifiers
    let onOpenResults: () -> Void
    let onClose: () -> Void
    /// Offered only where a caller can actually run extraction again. Nil leaves this screen
    /// exactly what it was.
    var onRetryAnalysis: (() async -> Void)?
    /// Owned by the caller, because the run is. Disables the button rather than hiding it, so the
    /// screen does not reshuffle while the user is looking at it.
    var isRetryingAnalysis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("회의가 저장되었습니다"))
                .font(.title2)
                .bold()
                .accessibilityIdentifier(identifiers.savedMessage)

            Text(outcome.meetingTitle)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(outcome.meetingTitle)
                .accessibilityIdentifier("capture-completion-meeting-title")

            Text(L10n.text(outcome.preservation.localizationKey))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("capture-preservation-message")

            Text(L10n.text(CapturePresentationCopy.candidates)).font(.headline)
                .accessibilityIdentifier("capture-candidates-heading")
            Text(L10n.text(CapturePresentationCopy.approvalNotice))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("capture-unapproved-notice")
            results

            if let notice = outcome.notice {
                // Not an error state: the meeting is saved and reachable, and the button below
                // still works. This says which of the steps after the save did not happen.
                Text(L10n.text(notice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-completion-notice")

                retryAnalysis
            }

            Spacer(minLength: 0)

            HStack {
                Button(L10n.text("닫기"), action: onClose)
                    .accessibilityIdentifier(identifiers.closeButton)

                Spacer()

                Button(L10n.text("결과 확인"), action: onOpenResults)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("capture-open-results-button")
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 300, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-completion-screen")
    }

    // MARK: - Retry

    /// Shown beside the notice, and only beside it: a capture whose extraction succeeded has
    /// nothing to retry, and offering it anyway would invite a second provider request for results
    /// the meeting already has.
    ///
    /// It sits here rather than only on the meeting screen because this is where the user is
    /// standing when the failure is reported — but it is deliberately not the only place. This
    /// sheet closes, and a retry that existed nowhere else would be gone for good the moment it
    /// did.
    @ViewBuilder
    private var retryAnalysis: some View {
        if let onRetryAnalysis {
            HStack(spacing: 8) {
                Button(UIMeetingReanalysisCopy.button) {
                    Task { await onRetryAnalysis() }
                }
                .disabled(isRetryingAnalysis)
                .accessibilityIdentifier("capture-retry-analysis-button")

                if isRetryingAnalysis {
                    ProgressView(L10n.text(CaptureProgressPhase.retrying.localizationKey))
                        .controlSize(.small)
                        .accessibilityIdentifier("capture-retry-analysis-progress")
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Results

    /// Pending AI proposals in all four kinds, including the ones that came back empty.
    ///
    /// A meeting that produced no decisions is a fact worth showing: hiding the row would leave
    /// the user unsure whether the app looked for them at all, which is exactly the doubt this
    /// screen exists to remove.
    @ViewBuilder
    private var results: some View {
        if let counts = outcome.pendingCounts {
            VStack(alignment: .leading, spacing: 6) {
                resultRow(L10n.text("결정 사항"), counts.decisions, identifier: "capture-count-decisions")
                resultRow(L10n.text("실행 항목"), counts.actionItems, identifier: "capture-count-action-items")
                resultRow(L10n.text("미해결 질문"), counts.openQuestions, identifier: "capture-count-open-questions")
                resultRow(L10n.text("다음 아젠다"), counts.agendaItems, identifier: "capture-count-next-agenda")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        } else {
            // The save succeeded but pending counts could not be read back. Saying "0건" here would
            // be a claim about the meeting that nothing has checked.
            Text(L10n.text(CapturePresentationCopy.countsUnavailable))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("capture-counts-unavailable")
        }
    }

    private func resultRow(_ title: String, _ count: Int, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(L10n.format("%@건", String(describing: count)))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    CaptureCompletionView(
        outcome: CaptureOutcome(
            destination: CaptureDestination(projectID: UUID(), meetingID: UUID()),
            meetingTitle: "주간 제품 회의",
            counts: CaptureResultCounts(decisions: 2, actionItems: 4, openQuestions: 1, agendaItems: 0),
            notice: nil
        ),
        identifiers: .pastedText,
        onOpenResults: {},
        onClose: {}
    )
}
