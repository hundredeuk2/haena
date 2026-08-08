import SwiftUI

/// Detail pane for a single meeting: metadata plus its transcript, rendered in stored order.
struct MeetingDetailView: View {
    let meeting: Meeting
    let deletionErrorMessage: String?
    let onDeleteMeeting: () async -> Void
    /// Supplied where speaker confirmation is available. Nil keeps this view usable on its own —
    /// the banner simply never appears.
    var speakerConfirmation: SpeakerConfirmationService?
    var onSpeakersChanged: (() async -> Void)?
    var pasteboardWriter: any PasteboardWriter = SystemPasteboardWriter()
    var fileExporter: any MarkdownFileExporter = SavePanelMarkdownExporter()

    @State private var isConfirmingDeletion = false
    @State private var isConfirmingSpeakers = false
    @State private var exportFeedback: ExportFeedback?

    private struct ExportFeedback: Equatable {
        let message: String
        let isError: Bool
    }
    /// Dismissing the banner hides it for this viewing only. It is not a decision that gets
    /// stored: nothing is deleted or permanently hidden, and re-opening the meeting offers it
    /// again for as long as any voice is still unidentified.
    @State private var isBannerDismissed = false

    private let dateFormatter = MeetingDateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title)
                    .font(.title2)
                    .bold()
                    // A long title wraps instead of pushing the actions off the pane.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting-detail-title")

                Spacer(minLength: 12)

                Button("원문 복사") {
                    copyTranscript()
                }
                .accessibilityIdentifier("copy-transcript-button")
                .disabled(!hasExportableTranscript)

                Button("원문 내보내기") {
                    exportTranscript()
                }
                .accessibilityIdentifier("export-transcript-button")
                .disabled(!hasExportableTranscript)

                Button("회의 삭제", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .accessibilityIdentifier("delete-meeting-button")
            }

            if let exportFeedback {
                Text(exportFeedback.message)
                    .font(.callout)
                    .foregroundStyle(exportFeedback.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("transcript-export-feedback-message")
            }

            HStack(spacing: 16) {
                Text(dateFormatter.string(from: meeting.occurredAt))
                Text(MeetingSourceTypeDisplay.label(for: meeting.sourceType))
                    .accessibilityIdentifier("meeting-detail-source-type")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !meeting.assignableParticipants.isEmpty {
                Text("참석자 " + meeting.assignableParticipants.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let deletionErrorMessage {
                Text(deletionErrorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("meeting-deletion-error-message")
            }

            unconfirmedSpeakerBanner

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(meeting.transcriptSegments) { segment in
                        TranscriptSegmentRow(segment: segment, meeting: meeting)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("transcript-segment-\(segment.id.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting-transcript")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-detail-screen")
        .sheet(isPresented: $isConfirmingDeletion) {
            DeletionConfirmationView(
                title: "“\(meeting.title)” 회의를 삭제할까요?",
                message: "이 회의와 연결된 추출 결과가 함께 삭제됩니다.\n이 작업은 앱에서 복구할 수 없습니다.",
                confirmButtonIdentifier: "confirm-delete-meeting-button",
                cancelButtonIdentifier: "cancel-delete-meeting-button",
                onConfirm: {
                    await onDeleteMeeting()
                    isConfirmingDeletion = false
                },
                onCancel: {
                    isConfirmingDeletion = false
                }
            )
        }
        .sheet(isPresented: $isConfirmingSpeakers) {
            if let speakerConfirmation {
                SpeakerConfirmationView(
                    projectID: meeting.projectID,
                    meetingID: meeting.id,
                    service: speakerConfirmation,
                    onChanged: {
                        await onSpeakersChanged?()
                    }
                )
            }
        }
    }

    // MARK: - Transcript export

    /// Driven by the transcript, not by the audio: a pasted-text meeting, or one whose recording
    /// has since been deleted, still has words worth exporting.
    private var hasExportableTranscript: Bool {
        MeetingTranscriptMarkdownRenderer.hasExportableContent(meeting)
    }

    /// Built at the moment it is asked for, and from one function, so the file and the clipboard
    /// are physically incapable of containing different text.
    private func transcriptMarkdown() -> String {
        MeetingTranscriptMarkdownRenderer().render(meeting: meeting)
    }

    private func copyTranscript() {
        // Nothing to copy means the pasteboard is left exactly as the user had it.
        guard hasExportableTranscript else {
            return
        }
        if pasteboardWriter.write(transcriptMarkdown()) {
            show(ExportFeedback(message: "복사됨", isError: false))
        } else {
            show(ExportFeedback(message: "클립보드에 복사하지 못했습니다.", isError: true))
        }
    }

    private func exportTranscript() {
        guard hasExportableTranscript else {
            return
        }
        let outcome = fileExporter.export(
            transcriptMarkdown(),
            suggestedFilename: MeetingTranscriptMarkdownRenderer.filename(for: meeting)
        )
        switch outcome {
        case .saved:
            show(ExportFeedback(message: "저장됨", isError: false))
        case .cancelled:
            // Nothing to say: the user closed the panel on purpose.
            break
        case .failed:
            show(ExportFeedback(message: "파일을 저장하지 못했습니다.", isError: true))
        }
    }

    /// Clears itself, so the confirmation reads as being about the action just taken rather than
    /// lingering beside a button the user might press again. Never blocks the screen.
    private func show(_ newFeedback: ExportFeedback) {
        exportFeedback = newFeedback
        Task {
            try? await Task.sleep(for: .seconds(2))
            if exportFeedback == newFeedback {
                exportFeedback = nil
            }
        }
    }

    /// An inline row, never a modal that opens by itself: the meeting is already complete and
    /// usable, so this is an offer rather than a question the user has to answer.
    @ViewBuilder
    private var unconfirmedSpeakerBanner: some View {
        let unconfirmed = meeting.unconfirmedSpeakers
        if speakerConfirmation != nil, !unconfirmed.isEmpty, !isBannerDismissed {
            HStack(spacing: 12) {
                Text("확인되지 않은 화자 \(unconfirmed.count)명")
                    .font(.caption)
                    .accessibilityIdentifier("unconfirmed-speaker-banner")

                Button("화자 확인") {
                    isConfirmingSpeakers = true
                }
                .accessibilityIdentifier("confirm-speakers-button")

                Button("나중에") {
                    isBannerDismissed = true
                }
                .accessibilityIdentifier("dismiss-speaker-banner-button")
            }
        }
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let meeting: Meeting

    private var speakerLabel: String? {
        TranscriptSpeakerDisplay.label(for: segment, in: meeting)
    }

    private var timestampLabel: String? {
        TranscriptTimestampFormatter.string(from: segment.startTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if speakerLabel != nil || timestampLabel != nil {
                HStack(spacing: 8) {
                    if let speakerLabel {
                        Text(speakerLabel)
                            .font(.caption)
                            .bold()
                    }
                    if let timestampLabel {
                        Text(timestampLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(segment.text)
                .textSelection(.enabled)
        }
    }
}
