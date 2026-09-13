import SwiftUI

/// Plays back a meeting's stored recording, inline in the meeting detail pane.
///
/// The same view serves a microphone recording and an imported file: by the time a meeting has an
/// `AudioAsset`, how the audio arrived is no longer part of the question. It is deliberately an
/// aside on the screen — the transcript remains the point, and every failure here leaves the rest
/// of the meeting fully usable.
struct MeetingAudioPlayerView: View {
    @StateObject private var model: MeetingAudioPlaybackModel

    init(fileURL: URL, makePlayer: @escaping () -> any MeetingAudioPlayer) {
        _model = StateObject(wrappedValue: MeetingAudioPlaybackModel(player: makePlayer(), fileURL: fileURL))
    }

    /// Only ticks while something is playing; the model ignores it otherwise.
    ///
    /// `@State` rather than a plain `let`: this struct is rebuilt on every published change — which
    /// is every tick while playing — and a stored-property initializer would hand `onReceive` a
    /// brand new publisher each time, tearing down and restarting the timer continuously. One timer
    /// per player, created once.
    @State private var ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(model.isPlaying ? L10n.text("일시정지") : L10n.text("재생")) {
                    Task { await model.togglePlayPause() }
                }
                .accessibilityIdentifier("meeting-audio-play-pause-button")
                .disabled(!model.isLoaded)

                Button(L10n.text("처음부터")) {
                    Task { await model.restart() }
                }
                .accessibilityIdentifier("meeting-audio-restart-button")
                .disabled(!model.canRestart)

                // Text, not a progress bar alone: the exact position has to be readable, and the
                // shape matches the transcript timestamps beside it.
                Text("\(model.currentTimeText) / \(model.durationText)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-audio-time-label")

                if model.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("meeting-audio-loading-progress")
                }

                Spacer(minLength: 0)
            }

            if let errorMessage = model.errorMessage {
                HStack(spacing: 8) {
                    Text(L10n.text(errorMessage))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meeting-audio-error-message")

                    Button(L10n.text("다시 시도")) {
                        Task { await model.load() }
                    }
                    .accessibilityIdentifier("meeting-audio-retry-button")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-audio-player")
        .task {
            await model.load()
        }
        .onReceive(ticker) { _ in
            Task { await model.tick() }
        }
        .onDisappear {
            // Leaving the pane — or selecting a different meeting, which replaces this view — must
            // not leave audio playing out of a screen no one is looking at.
            let model = self.model
            Task { await model.stop() }
        }
    }
}
