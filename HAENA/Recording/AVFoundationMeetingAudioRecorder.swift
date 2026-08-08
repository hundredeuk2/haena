import AVFoundation
import Foundation

/// The real microphone, behind an `actor`.
///
/// `AVAudioRecorder` is not `Sendable`, and Swift 6 is right to refuse it crossing concurrency
/// domains: it is a stateful object driven from several places (start, stop, teardown on quit).
/// Rather than silence that with `@unchecked Sendable`, the recorder is stored as actor-isolated
/// state, so the compiler proves that only one task touches it at a time. Nothing hands the
/// `AVAudioRecorder` itself out; only value types cross the boundary.
actor AVFoundationMeetingAudioRecorder: MeetingAudioRecorder {
    /// AAC in an `.m4a` container, mono: exactly what `AudioFileValidator` accepts and what the
    /// transcription endpoint takes, at a size that keeps an hour-long meeting well under the
    /// 25 MB upload ceiling. Speech, not music — mono at 64 kbps is the point of diminishing
    /// returns for intelligibility, and this is not an audio-quality tuning exercise.
    ///
    /// Computed rather than a stored static: `[String: Any]` is not `Sendable`, and a shared
    /// stored instance would be exactly the global mutable state Swift 6 is right to reject.
    /// Building it per call costs nothing next to opening an audio device.
    private static var settings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
    }

    /// Shorter than this and there is nothing worth transcribing — a stop pressed by accident
    /// right after start. Reported as a failure rather than sent to a provider that would bill
    /// for silence.
    private static let minimumUsableDuration: TimeInterval = 0.3

    nonisolated var fileExtension: String { "m4a" }

    private var recorder: AVAudioRecorder?
    private var destination: URL?

    func authorizationStatus() async -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            // A state this build does not know about is treated as "cannot record" rather than
            // assumed permissive.
            return .restricted
        }
    }

    func requestAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording(to destination: URL) async throws {
        guard recorder == nil else {
            throw MeetingAudioRecorderError.alreadyRecording
        }

        switch await authorizationStatus() {
        case .authorized:
            break
        case .denied, .notDetermined:
            // `.notDetermined` reaching here means the caller skipped the request step; refusing
            // is safer than prompting from inside the recorder, where the UI cannot explain why.
            throw MeetingAudioRecorderError.permissionDenied
        case .restricted:
            throw MeetingAudioRecorderError.permissionRestricted
        }

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MeetingAudioRecorderError.noInputDevice
        }

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: destination, settings: Self.settings)
        } catch {
            // The underlying error is dropped rather than wrapped: its description can contain
            // the full destination path.
            throw MeetingAudioRecorderError.startFailed
        }

        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            throw MeetingAudioRecorderError.startFailed
        }

        recorder = newRecorder
        self.destination = destination
    }

    func stopRecording() async throws -> RecordedAudio {
        guard let recorder, let destination else {
            throw MeetingAudioRecorderError.notRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.destination = nil

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw MeetingAudioRecorderError.fileWriteFailed
        }
        let byteSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)??.intValue ?? 0

        // Both checks matter: a file can exist with only a container header after a stop that
        // arrived before any audio did.
        guard duration >= Self.minimumUsableDuration, byteSize > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw MeetingAudioRecorderError.noAudioCaptured
        }

        return RecordedAudio(fileURL: destination, duration: duration, byteSize: byteSize)
    }

    func cancelRecording() async {
        recorder?.stop()
        recorder = nil
        if let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        destination = nil
    }
}
