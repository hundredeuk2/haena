import SwiftUI

/// Which half of a meeting is showing.
private enum MeetingDetailPane: String, CaseIterable, Identifiable {
    /// What the meeting turned into. The default: a meeting is worth opening for what came of it,
    /// and the transcript is the evidence behind that rather than the point of it.
    case results
    case transcript

    var id: String { rawValue }
}

/// Detail pane for a single meeting: what the meeting produced, with its transcript one tab away.
///
/// Built with `.id(meeting.id)` at its call site, so a different meeting is a different view. Every
/// piece of per-meeting view state below — the selected tab, the export banner, the dismissed
/// speaker banner, and the scroll offsets and disclosure state inside the two panes — is discarded
/// with it. That is the only way the scroll offsets can be cleared at all: they belong to SwiftUI,
/// not to any property here.
struct MeetingDetailView: View {
    /// The meeting's project, needed because a meeting's results are stored on the project rather
    /// than inside the meeting — and because every verdict is applied by project id.
    let project: Project
    let meeting: Meeting
    let deletionErrorMessage: String?
    let onDeleteMeeting: () async -> Void
    let reviewService: WorkStateReviewService
    /// Reloads the project after a verdict, so the four areas show what was actually persisted.
    let onWorkStateChanged: () async -> Void
    /// Supplied where speaker confirmation is available. Nil keeps this view usable on its own —
    /// the banner simply never appears.
    var speakerConfirmation: SpeakerConfirmationService?
    var onSpeakersChanged: (() async -> Void)?
    var pasteboardWriter: any PasteboardWriter = SystemPasteboardWriter()
    var fileExporter: any MarkdownFileExporter = SavePanelMarkdownExporter()
    /// Supplied where stored audio can be resolved. Nil keeps this view usable on its own — the
    /// player simply never appears, exactly as for a meeting that has no recording.
    var audioAssetStore: AudioAssetStore?
    /// A fresh player per meeting, chosen at the app's assembly point like every other boundary.
    var makeAudioPlayer: () -> any MeetingAudioPlayer = { AVFoundationMeetingAudioPlayer() }

    @State private var isConfirmingDeletion = false
    @State private var isConfirmingSpeakers = false
    @State private var exportFeedback: ExportFeedback?
    @State private var pane: MeetingDetailPane = .results

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
                    // A long title wraps rather than pushing 회의 삭제 off the pane — but only so
                    // far. This header does not scroll, so every line it grows is a line the whole
                    // browser grows with it: the auto-generated recording title
                    // "Aug 9, 2026 at 1:00 AM 녹음" wraps to three lines in a narrow column, and
                    // that alone was enough to push the split view past the height the window could
                    // give it, leaving the title centred off the top edge. The full title stays
                    // available on hover.
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(meeting.title)
                    .accessibilityIdentifier("meeting-detail-title")

                Spacer(minLength: 12)

                Button("회의 삭제", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .accessibilityIdentifier("delete-meeting-button")
            }

            HStack(spacing: 16) {
                Text(dateFormatter.string(from: meeting.occurredAt))
                Text(MeetingSourceTypeDisplay.label(for: meeting.sourceType))
                    .accessibilityIdentifier("meeting-detail-source-type")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !meeting.assignableParticipants.isEmpty {
                // Bounded for the same reason as the title: a meeting with many participants must
                // not be able to grow this header without limit.
                let roster = meeting.assignableParticipants.map(\.displayName).joined(separator: ", ")
                Text("참석자 " + roster)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(roster)
            }

            if let deletionErrorMessage {
                Text(deletionErrorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("meeting-deletion-error-message")
            }

            // Above the picker on purpose: listening back is how a user checks either half, and
            // having the player disappear when they switch tabs would stop the recording mid-word.
            audioPlayer

            Divider()

            Picker("표시", selection: $pane) {
                Text("회의 결과").tag(MeetingDetailPane.results)
                Text("원문").tag(MeetingDetailPane.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("meeting-detail-pane-picker")

            // Whichever pane is showing scrolls within the space left over from the header above,
            // and never asks for more than that. The header is the one part of this screen that
            // must always be reachable — it carries the title, the tab picker and 회의 삭제 — so a
            // pane whose content is taller than the pane must scroll inside itself rather than
            // grow the column it sits in.
            Group {
                switch pane {
                case .results:
                    MeetingResultsView(
                        project: project,
                        meeting: meeting,
                        reviewService: reviewService,
                        onChanged: onWorkStateChanged
                    )

                case .transcript:
                    transcriptPane
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Transcript pane

    /// Everything the transcript view had before the results screen was put in front of it: the
    /// speaker banner, the segments in stored order, and the two ways to take the text out.
    ///
    /// Copy and export live here rather than in the header because they are about the transcript
    /// specifically — and they behave identically for a recorded meeting, an imported file and
    /// pasted text, since all three arrive here as the same segments.
    @ViewBuilder
    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
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

                if let exportFeedback {
                    Text(exportFeedback.message)
                        .font(.callout)
                        .foregroundStyle(exportFeedback.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("transcript-export-feedback-message")
                }

                Spacer()
            }

            unconfirmedSpeakerBanner

            // The one part of this pane that grows: a long transcript scrolls here rather than
            // stretching the pane past the bottom of the column.
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
            // Same reasoning as the results pane: a transcript of any length must not become a
            // height this screen asks the window for. See `MeetingResultsView`.
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting-transcript")
        }
        .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-transcript-pane")
    }

    // MARK: - Audio playback

    /// Shown only when this meeting has a stored recording — which is the same condition for a
    /// microphone recording and an imported file, and never true for pasted text.
    ///
    /// `.id` on the asset is what makes switching meetings safe: SwiftUI reuses this pane for the
    /// next selection, so without a changing identity the previous meeting's player would be
    /// handed a new file while still holding the old one. A new identity tears the old player
    /// down — `onDisappear` stops it — and builds a fresh one.
    @ViewBuilder
    private var audioPlayer: some View {
        if let asset = meeting.audioAsset,
           let url = MeetingAudioPlayback.fileURL(for: meeting, in: audioAssetStore) {
            MeetingAudioPlayerView(fileURL: url, makePlayer: makeAudioPlayer)
                .id(asset.id)
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
