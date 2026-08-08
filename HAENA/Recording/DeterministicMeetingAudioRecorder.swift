import Foundation

/// A recorder that never touches a microphone.
///
/// It writes a real, valid WAV file — a header plus silence, synthesized in code — so the rest of
/// the flow is exercised for real: the file passes `AudioFileValidator`, gets copied by
/// `AudioMeetingCaptureStore`, and reaches the transcription boundary exactly as a genuine
/// recording would. Nothing is bundled as a fixture, no permission prompt appears, and no audio
/// hardware is opened.
///
/// Wired in **only** at the app's assembly point when launched under UI test, alongside the
/// deterministic extractor and transcription provider, and never substituted for the real recorder
/// when that one fails — a user must never believe they recorded something they did not.
actor DeterministicMeetingAudioRecorder: MeetingAudioRecorder {
    /// Lets a test drive the paths that a real machine would reach only by unplugging hardware or
    /// changing System Settings.
    enum Behavior: Sendable, Equatable {
        case succeeds
        case permissionNotDetermined(grantWhenAsked: Bool)
        case permissionDenied
        case permissionRestricted
        case noInputDevice
        case startFails
        /// Stop produces a file with no audio in it.
        case producesEmptyRecording
    }

    /// WAV, because this writes PCM by hand rather than encoding AAC. Declaring it keeps the
    /// produced file honest about what is inside it.
    nonisolated var fileExtension: String { "wav" }

    private let behavior: Behavior
    private let sampleRate: Int
    /// Seconds of silence written on stop. Fixed, so a test asserting on duration is not timing
    /// dependent.
    private let recordedDuration: TimeInterval

    private var status: MicrophoneAuthorizationStatus
    private var destination: URL?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    init(
        behavior: Behavior = .succeeds,
        recordedDuration: TimeInterval = 2,
        sampleRate: Int = 44_100
    ) {
        self.behavior = behavior
        self.recordedDuration = recordedDuration
        self.sampleRate = sampleRate
        switch behavior {
        case .permissionNotDetermined:
            status = .notDetermined
        case .permissionDenied:
            status = .denied
        case .permissionRestricted:
            status = .restricted
        default:
            status = .authorized
        }
    }

    func authorizationStatus() async -> MicrophoneAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> Bool {
        guard case .permissionNotDetermined(let grant) = behavior else {
            return status == .authorized
        }
        status = grant ? .authorized : .denied
        return grant
    }

    func startRecording(to destination: URL) async throws {
        guard self.destination == nil else {
            throw MeetingAudioRecorderError.alreadyRecording
        }
        switch status {
        case .authorized:
            break
        case .denied, .notDetermined:
            throw MeetingAudioRecorderError.permissionDenied
        case .restricted:
            throw MeetingAudioRecorderError.permissionRestricted
        }
        switch behavior {
        case .noInputDevice:
            throw MeetingAudioRecorderError.noInputDevice
        case .startFails:
            throw MeetingAudioRecorderError.startFailed
        default:
            break
        }

        startCount += 1
        self.destination = destination
    }

    func stopRecording() async throws -> RecordedAudio {
        guard let destination else {
            throw MeetingAudioRecorderError.notRecording
        }
        stopCount += 1
        self.destination = nil

        if case .producesEmptyRecording = behavior {
            throw MeetingAudioRecorderError.noAudioCaptured
        }

        let data = Self.silentWAVData(seconds: recordedDuration, sampleRate: sampleRate)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw MeetingAudioRecorderError.fileWriteFailed
        }

        return RecordedAudio(fileURL: destination, duration: recordedDuration, byteSize: data.count)
    }

    func cancelRecording() async {
        cancelCount += 1
        if let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        destination = nil
    }

    // MARK: - Synthesized audio

    /// A minimal but genuinely well-formed 16-bit mono PCM WAV. Real enough that the validator and
    /// every file-handling step downstream behave exactly as they would with a microphone.
    static func silentWAVData(seconds: TimeInterval, sampleRate: Int) -> Data {
        let frameCount = max(1, Int(Double(sampleRate) * seconds))
        let bytesPerFrame = 2
        let dataBytes = frameCount * bytesPerFrame

        var data = Data()
        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                                        // PCM header size
        appendUInt16(1)                                         // PCM format
        appendUInt16(1)                                         // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerFrame))        // byte rate
        appendUInt16(UInt16(bytesPerFrame))                     // block align
        appendUInt16(16)                                        // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }
}
