import AVFoundation
import Foundation

/// The real player, built on `AVAudioPlayer`.
///
/// An `actor` because `AVAudioPlayer` is not `Sendable` and is mutated by every control here.
/// Keeping it inside an actor lets the compiler prove single access rather than asking anyone to
/// take `@unchecked Sendable` on trust; only value types cross the boundary.
///
/// Nothing here converts, re-encodes, or seeks anywhere but the start — playback of the stored
/// file exactly as it was recorded or imported.
actor AVFoundationMeetingAudioPlayer: MeetingAudioPlayer {
    private var player: AVAudioPlayer?

    func load(_ url: URL) throws -> TimeInterval {
        // Checked first so a recording deleted from underneath the app reports the accurate
        // reason, rather than being reported as a decoding failure.
        guard FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            throw MeetingAudioPlayerError.fileMissing
        }

        let created: AVAudioPlayer
        do {
            created = try AVAudioPlayer(contentsOf: url)
        } catch {
            player = nil
            throw MeetingAudioPlayerError.unreadableAudio
        }

        // A truncated or empty file can still open. Treating a zero-length duration as unreadable
        // keeps the UI from offering a play button that could never do anything.
        guard created.duration > 0 else {
            player = nil
            throw MeetingAudioPlayerError.unreadableAudio
        }

        created.prepareToPlay()
        player = created
        return created.duration
    }

    func play() throws {
        guard let player else {
            throw MeetingAudioPlayerError.playbackFailed
        }
        guard player.play() else {
            throw MeetingAudioPlayerError.playbackFailed
        }
    }

    func pause() {
        player?.pause()
    }

    func seekToStart() {
        player?.currentTime = 0
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
    }

    /// Both values off the same player in one actor-isolated read, so nothing can pause between
    /// them.
    func snapshot() -> PlaybackSnapshot {
        guard let player else {
            return PlaybackSnapshot(currentTime: 0, isPlaying: false)
        }
        return PlaybackSnapshot(currentTime: player.currentTime, isPlaying: player.isPlaying)
    }
}
