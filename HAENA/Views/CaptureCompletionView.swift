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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("회의가 저장되었습니다")
                .font(.title2)
                .bold()
                .accessibilityIdentifier(identifiers.savedMessage)

            Text(outcome.meetingTitle)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(outcome.meetingTitle)
                .accessibilityIdentifier("capture-completion-meeting-title")

            results

            if let notice = outcome.notice {
                // Not an error state: the meeting is saved and reachable, and the button below
                // still works. This says which of the steps after the save did not happen.
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-completion-notice")
            }

            Spacer(minLength: 0)

            HStack {
                Button("닫기", action: onClose)
                    .accessibilityIdentifier(identifiers.closeButton)

                Spacer()

                Button("결과 확인", action: onOpenResults)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("capture-open-results-button")
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 300, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-completion-screen")
    }

    // MARK: - Results

    /// All four kinds, always — including the ones that came back empty.
    ///
    /// A meeting that produced no decisions is a fact worth showing: hiding the row would leave
    /// the user unsure whether the app looked for them at all, which is exactly the doubt this
    /// screen exists to remove.
    @ViewBuilder
    private var results: some View {
        if let counts = outcome.counts {
            VStack(alignment: .leading, spacing: 6) {
                resultRow("결정 사항", counts.decisions, identifier: "capture-count-decisions")
                resultRow("실행 항목", counts.actionItems, identifier: "capture-count-action-items")
                resultRow("미해결 질문", counts.openQuestions, identifier: "capture-count-open-questions")
                resultRow("다음 아젠다", counts.agendaItems, identifier: "capture-count-next-agenda")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        } else {
            // The save succeeded but the project could not be read back. Saying "0건" here would
            // be a claim about the meeting that nothing has checked.
            Text("저장된 결과 건수를 확인하지 못했습니다. 회의는 저장되어 있습니다.")
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
            Text("\(count)건")
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
