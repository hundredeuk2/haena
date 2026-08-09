import Foundation

/// A player that never opens an audio device.
///
/// Its playhead moves only when a test moves it, so every playback state — mid-play, paused,
/// restarted, run to the end — is reachable without waiting in real time and without a sound
/// leaving the machine.
///
/// Wired in **only** at the app's assembly point when launched under UI test, alongside the
/// deterministic recorder, extractor, and transcription provider. It is never substituted for the
/// real player when that one fails: a user must never be shown a playing indicator for audio no
/// one can hear.
actor DeterministicMeetingAudioPlayer: MeetingAudioPlayer {
    /// Lets a test drive the paths a real machine reaches only through a deleted file, a corrupt
    /// recording, or an audio device that refuses to start.
    enum Behavior: Sendable, Equatable {
        case succeeds
        case fileMissing
        case unreadableAudio
        case playbackFails
    }

    private let behavior: Behavior
    private let duration: TimeInterval

    private var isLoaded = false
    private var playing = false
    private var time: TimeInterval = 0

    private(set) var loadCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seekCount = 0
    private(set) var stopCount = 0

    init(behavior: Behavior = .succeeds, duration: TimeInterval = 12) {
        self.behavior = behavior
        self.duration = duration
    }

    func load(_ url: URL) throws -> TimeInterval {
        loadCount += 1
        switch behavior {
        case .fileMissing:
            throw MeetingAudioPlayerError.fileMissing
        case .unreadableAudio:
            throw MeetingAudioPlayerError.unreadableAudio
        case .succeeds, .playbackFails:
            isLoaded = true
            time = 0
            return duration
        }
    }

    func play() throws {
        guard isLoaded, behavior != .playbackFails else {
            throw MeetingAudioPlayerError.playbackFailed
        }
        playCount += 1
        playing = true
    }

    func pause() {
        pauseCount += 1
        playing = false
    }

    func seekToStart() {
        seekCount += 1
        time = 0
    }

    func stop() {
        stopCount += 1
        playing = false
        time = 0
    }

    func snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(currentTime: time, isPlaying: playing)
    }

    // MARK: - Test control

    /// Moves the playhead as if that many seconds of audio had been played. Reaching the end stops
    /// playback, exactly as the real player does when a file runs out.
    func advance(by seconds: TimeInterval) {
        guard playing else {
            return
        }
        time += seconds
        if time >= duration {
            time = duration
            playing = false
        }
    }

    /// Stops playback mid-file without moving the playhead, leaving the player in the state
    /// something outside the model would leave it in — a pause that has already taken effect, an
    /// unplugged device. Distinct from reaching the end, and it must not be mistaken for one.
    func interrupt() {
        playing = false
    }
}
