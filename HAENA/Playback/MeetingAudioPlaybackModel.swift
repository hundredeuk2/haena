import Combine
import Foundation

/// Finds the stored recording a meeting can play, if it has one.
///
/// One function for every input method on purpose: a microphone recording and an imported file
/// both end up as an `AudioAsset` in the same store, so neither can end up with a different
/// playback offer than the other. Meetings with no audio — pasted text, or a recording already
/// deleted — return nil and simply get no player.
enum MeetingAudioPlayback {
    static func fileURL(for meeting: Meeting, in store: AudioAssetStore?) -> URL? {
        guard let store, let asset = meeting.audioAsset else {
            return nil
        }
        return store.url(for: asset)
    }
}

/// Playback state for one meeting's recording.
///
/// All of the decisions live here rather than in the view, so they can be tested directly: which
/// control a press means, what the elapsed time is, when a file counts as finished, and what
/// happens when it turns out to be missing or corrupt. The view renders this and forwards presses.
@MainActor
final class MeetingAudioPlaybackModel: ObservableObject {
    /// One value rather than several booleans, so "playing but also failed" cannot be represented.
    enum Phase: Equatable {
        case idle
        case loading
        /// Loaded and stopped — either not started yet, or paused partway through.
        case ready
        case playing
        /// Reached the end of the file. Pressing play from here starts again from the beginning.
        case finished
        case failed(MeetingAudioPlayerError)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let player: any MeetingAudioPlayer
    private let fileURL: URL

    init(player: any MeetingAudioPlayer, fileURL: URL) {
        self.player = player
        self.fileURL = fileURL
    }

    // MARK: - Derived state

    var isPlaying: Bool {
        phase == .playing
    }

    /// True once there is a file to act on. Every control is disabled until then, and while the
    /// file is being opened.
    var isLoaded: Bool {
        switch phase {
        case .ready, .playing, .finished:
            return true
        case .idle, .loading, .failed:
            return false
        }
    }

    /// Restarting a file that has not begun would do nothing, so the control is not offered.
    var canRestart: Bool {
        isLoaded && (phase != .ready || currentTime > 0)
    }

    var errorMessage: String? {
        guard case .failed(let error) = phase else {
            return nil
        }
        switch error {
        case .fileMissing:
            return "녹음 파일을 찾을 수 없습니다. 전사된 내용은 그대로 사용할 수 있습니다."
        case .unreadableAudio:
            return "녹음 파일을 재생할 수 없습니다. 전사된 내용은 그대로 사용할 수 있습니다."
        case .playbackFailed:
            return "재생을 시작하지 못했습니다. 다른 앱이 오디오 장치를 사용 중인지 확인해주세요."
        }
    }

    /// Reuses the transcript's own timestamp format, so the playhead and the segment headings on
    /// the same screen read the same way.
    var currentTimeText: String {
        TranscriptTimestampFormatter.string(from: currentTime) ?? "00:00"
    }

    var durationText: String {
        TranscriptTimestampFormatter.string(from: duration) ?? "00:00"
    }

    // MARK: - Actions

    /// Opens the file. Called when the player appears; a second call while already loaded is
    /// ignored, so a redraw cannot restart or reopen anything.
    func load() async {
        switch phase {
        case .idle, .failed:
            break
        case .loading, .ready, .playing, .finished:
            return
        }

        phase = .loading
        do {
            let loadedDuration = try await player.load(fileURL)
            duration = loadedDuration
            currentTime = 0
            phase = .ready
        } catch let error as MeetingAudioPlayerError {
            fail(error)
        } catch {
            fail(.unreadableAudio)
        }
    }

    func togglePlayPause() async {
        switch phase {
        case .ready:
            await start(fromBeginning: false)
        case .finished:
            // The playhead is at the end; the only sensible reading of "play" is from the top.
            await start(fromBeginning: true)
        case .playing:
            await player.pause()
            // Read after pausing, so the stored position is where the audio actually stopped.
            // This is what resuming continues from — nothing seeks to zero on this path.
            currentTime = min(await player.snapshot().currentTime, duration)
            phase = .ready
        case .idle, .loading, .failed:
            break
        }
    }

    func restart() async {
        guard isLoaded else {
            return
        }
        await start(fromBeginning: true)
    }

    /// Teardown. Leaves the file loaded but silent and rewound, so the pane can be shown again
    /// without reopening anything, and so nothing keeps playing out of a screen the user left.
    func stop() async {
        await player.stop()
        currentTime = 0
        if isLoaded {
            phase = .ready
        }
    }

    /// Refreshes the elapsed time from the player rather than counting ticks, so a delayed or
    /// dropped tick cannot make the readout drift away from what is actually being heard.
    ///
    /// This runs on a timer, so it is always racing whatever the user is doing. Two rules keep it
    /// from overwriting their action: it re-checks the phase after its one suspension point, and it
    /// only calls a file finished when the playhead actually reached the end. A player that merely
    /// stopped is not a player that finished — mistaking one for the other is what turned a pause
    /// into a rewind.
    func tick() async {
        guard phase == .playing else {
            return
        }
        let snapshot = await player.snapshot()
        // The user may have pressed pause while this read was in flight.
        guard phase == .playing else {
            return
        }

        if snapshot.isPlaying {
            currentTime = min(snapshot.currentTime, duration)
        } else if hasReachedEnd(snapshot.currentTime) {
            currentTime = duration
            phase = .finished
        } else {
            // Stopped short of the end without going through this model. Keep the position, so
            // whatever happens next resumes from where the audio actually stopped.
            currentTime = min(snapshot.currentTime, duration)
            phase = .ready
        }
    }

    // MARK: - Private

    /// Whether a stopped player stopped because the file ran out.
    ///
    /// The tolerance is there because a player is not obliged to land exactly on the duration it
    /// reported, and some rewind to zero the instant a file completes — which is why a playhead at
    /// the start is read against the position this model last saw rather than taken at face value.
    private func hasReachedEnd(_ time: TimeInterval) -> Bool {
        guard duration > 0 else {
            return false
        }
        let tolerance = 0.5
        if time >= duration - tolerance {
            return true
        }
        return time <= tolerance && currentTime >= duration - tolerance
    }

    private func start(fromBeginning: Bool) async {
        if fromBeginning {
            await player.seekToStart()
            currentTime = 0
        }
        do {
            try await player.play()
            phase = .playing
        } catch let error as MeetingAudioPlayerError {
            fail(error)
        } catch {
            fail(.playbackFailed)
        }
    }

    /// A failure never leaves a stale playing state or a half-elapsed clock behind it.
    private func fail(_ error: MeetingAudioPlayerError) {
        phase = .failed(error)
        currentTime = 0
        duration = 0
    }
}
