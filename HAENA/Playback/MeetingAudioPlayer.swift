import Foundation

/// Why a stored recording could not be loaded or played back.
///
/// As elsewhere in this app, no case carries a system path or free text from the OS: an error must
/// not be able to put the user's home directory on screen or into a log.
enum MeetingAudioPlayerError: Error, Equatable, Sendable {
    /// The meeting still names a stored copy, but the file is no longer on disk.
    case fileMissing
    /// The file is there but is not audio this machine can decode, or holds no playable audio.
    case unreadableAudio
    /// Loading succeeded, but the system refused to start or continue playback.
    case playbackFailed
}

/// The seam between "play this meeting's recording" and AVFoundation.
///
/// It exists for the same reason as `MeetingAudioRecorder`: the whole playback flow — load,
/// play/pause, restart, elapsed time, teardown, and every failure path — has to be buildable and
/// verifiable on a machine that is not going to make a sound. Views and the playback model depend
/// on this protocol only; nothing outside the AVFoundation adapter constructs an `AVAudioPlayer`.
protocol MeetingAudioPlayer: Sendable {
    /// Opens the file and returns its duration in seconds. Throws rather than returning zero, so
    /// a caller cannot present a player for something with nothing in it.
    func load(_ url: URL) async throws -> TimeInterval
    func play() async throws
    func pause() async
    /// Moves the playhead back to the beginning without starting playback.
    func seekToStart() async
    /// Stops and returns to the beginning. Safe to call when nothing is playing, so teardown
    /// paths — a closed pane, a different meeting selected — can call it unconditionally.
    func stop() async
    func currentTime() async -> TimeInterval
    func isPlaying() async -> Bool
}
