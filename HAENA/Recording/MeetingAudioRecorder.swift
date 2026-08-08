import Foundation

/// Whether this app may use the microphone. Mirrors the system's own four states rather than
/// collapsing them, because they call for different responses: one can be resolved by asking,
/// one is already granted, and two can only be resolved by the user in System Settings.
enum MicrophoneAuthorizationStatus: Equatable, Sendable {
    /// Never asked. The only state where prompting is appropriate.
    case notDetermined
    case authorized
    /// The user said no. Asking again does nothing — the system will not show the prompt twice.
    case denied
    /// Blocked by policy (managed device, parental controls). Not the user's choice to reverse.
    case restricted
}

/// A finished recording, described by what the next stage needs: where the file is and whether it
/// contains anything.
struct RecordedAudio: Equatable, Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let byteSize: Int
}

/// Why a recording could not start, continue, or produce a usable file.
///
/// As elsewhere in this app, no case carries a system path or free text from the OS: an error must
/// not be able to put the user's home directory on screen or into a log.
enum MeetingAudioRecorderError: Error, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case noInputDevice
    case startFailed
    case alreadyRecording
    case notRecording
    /// The recording stopped on its own — a device was unplugged, or the session was taken away.
    case interrupted
    /// The file exists but holds no audio, e.g. stop pressed immediately after start.
    case noAudioCaptured
    case fileWriteFailed
}

/// The seam between "record this meeting" and AVFoundation.
///
/// It exists so the whole flow — permission, start, elapsed time, stop, cancel, hand-off to
/// transcription — can be built and verified on a machine with no microphone and no intention of
/// showing a permission prompt. Views and services depend on this protocol only; nothing outside
/// the AVFoundation adapter constructs or drives an `AVAudioRecorder`.
protocol MeetingAudioRecorder: Sendable {
    /// The container this recorder actually writes. Declared rather than assumed by the caller,
    /// so the file's name can never disagree with its contents — a `.m4a` holding WAV bytes would
    /// pass extension-based validation and then confuse whatever opened it.
    nonisolated var fileExtension: String { get }
    func authorizationStatus() async -> MicrophoneAuthorizationStatus
    /// Returns whether recording is now permitted. Only meaningful from `.notDetermined`; from
    /// `.denied` or `.restricted` it reports the existing answer without showing anything.
    func requestAuthorization() async -> Bool
    func startRecording(to destination: URL) async throws
    /// Returns the finished file. Throws rather than returning an empty recording, so a caller
    /// cannot hand a silent or zero-length file to transcription.
    func stopRecording() async throws -> RecordedAudio
    /// Stops and discards. Safe to call when nothing is recording, so teardown paths — a closed
    /// sheet, a quitting app — can call it unconditionally.
    func cancelRecording() async
}
