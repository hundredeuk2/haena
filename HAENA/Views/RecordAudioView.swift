import SwiftUI

/// Records a meeting from the microphone, then hands the file to the same screen that imports one
/// from disk.
///
/// It owns the recording only until it is either transcribed or abandoned: nothing is written to
/// the project, and no audio enters the app's managed store, until the user names the meeting and
/// confirms. Everything after that point is the existing import path, unchanged.
struct RecordAudioView: View {
    let recorder: any MeetingAudioRecorder
    let scratchStore: RecordingScratchStore
    let captureService: AudioMeetingCaptureService
    let extractionService: WorkStateExtractionService
    /// Forwarded to the import screen this hands over to, so a recording ends on the same
    /// completion screen — and the same 결과 확인 button — as an imported file.
    var onOpenResults: ((CaptureDestination) -> Void)?
    /// Injected so the elapsed time is testable and so it is measured from a monotonic-enough
    /// source rather than counted up by the timer's own tick count.
    var now: () -> Date = Date.init
    /// Forwarded to the import screen, which is where a recording's capture actually happens.
    ///
    /// Nothing is measured while the microphone is open: recording is the meeting itself, not the
    /// app processing it, and a two-hour recording is not a two-hour wait. The clock the beta
    /// cares about starts when the user hands the finished file over on the next screen.
    var metrics: BetaMetricsService?
    /// Passed straight through: a finished recording continues in `ImportAudioView`, and its
    /// completion screen is the one that can offer another attempt.
    var reanalysisService: MeetingReanalysisService?

    @Environment(\.dismiss) private var dismiss

    /// One value rather than several booleans, so "recording but also stopping" cannot be
    /// represented at all.
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case preparing
        case recording(startedAt: Date)
        case stopping
        case recorded(ValidatedAudioFile)
        case failed(String)

        /// Every phase where a second start, stop, or cancel would be a mistake.
        var isBusy: Bool {
            switch self {
            case .requestingPermission, .preparing, .stopping:
                return true
            case .idle, .recording, .recorded, .failed:
                return false
            }
        }

        var isRecording: Bool {
            if case .recording = self {
                return true
            }
            return false
        }
    }

    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    /// Tracked separately from `phase` so cleanup can find the file after a failure, and so an
    /// abandoned recording is always deletable.
    @State private var scratchURL: URL?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if case .recorded(let file) = phase {
                // The recording is finished; naming and transcription are the existing flow.
                ImportAudioView(
                    service: captureService,
                    extractionService: extractionService,
                    preselectedFile: file,
                    sourceType: .microphone,
                    heading: L10n.text("녹음 저장"),
                    onTranscribed: {
                        // The capture service has its own copy now.
                        discardScratchFile()
                    },
                    onOpenResults: onOpenResults,
                    metrics: metrics,
                    reanalysisService: reanalysisService
                )
            } else {
                recordingScreen
            }
        }
        .onReceive(ticker) { _ in
            guard case .recording(let startedAt) = phase else {
                return
            }
            // Derived from the start time, never accumulated from ticks, so a dropped or delayed
            // tick cannot make the clock drift or run backwards.
            elapsed = max(0, now().timeIntervalSince(startedAt))
        }
        .onDisappear {
            // Closing the sheet mid-recording must not leave the microphone open or a partial
            // file behind.
            let recorder = self.recorder
            Task { await recorder.cancelRecording() }
            discardScratchFile()
        }
    }

    // MARK: - Recording screen

    private var recordingScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("마이크 녹음"))
                .font(.title2)
                .bold()

            if phase.isRecording {
                HStack(spacing: 8) {
                    // Text and a symbol, not colour alone: colour is not available to every user.
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text(L10n.text("녹음 중"))
                        .bold()
                    Text(Self.elapsedText(elapsed))
                        .monospacedDigit()
                        .accessibilityIdentifier("recording-elapsed-time")
                }
                .accessibilityIdentifier("recording-indicator")
            } else {
                Text(L10n.text("회의를 녹음한 뒤 제목과 프로젝트를 선택하면 전사가 시작됩니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = phase {
                Text(L10n.text(message))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recording-error-message")
            }

            if phase == .requestingPermission {
                ProgressView(L10n.text("마이크 권한을 확인하는 중…"))
                    .accessibilityIdentifier("recording-permission-progress")
            }

            Spacer(minLength: 0)

            controls
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 240)
    }

    private var controls: some View {
        HStack {
            Button(L10n.text("닫기")) {
                dismiss()
            }
            .accessibilityIdentifier("close-recording-button")
            .disabled(phase.isBusy || phase.isRecording)

            Spacer()

            if phase.isRecording {
                Button(L10n.text("취소")) {
                    cancelRecording()
                }
                .accessibilityIdentifier("cancel-recording-button")
                .disabled(phase.isBusy)

                Button(L10n.text("녹음 종료")) {
                    stopRecording()
                }
                .accessibilityIdentifier("stop-recording-button")
                .disabled(phase.isBusy)
            } else {
                Button(startButtonTitle) {
                    startRecording()
                }
                .accessibilityIdentifier("start-recording-button")
                .disabled(phase.isBusy)
            }
        }
    }

    private var startButtonTitle: String {
        if case .failed = phase {
            return L10n.text("다시 시도")
        }
        return L10n.text("녹음 시작")
    }

    /// `mm:ss`, widening past an hour — the same shape as transcript timestamps.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }

    // MARK: - Actions

    private func startRecording() {
        guard !phase.isBusy, !phase.isRecording else {
            return
        }
        phase = .requestingPermission

        Task {
            // Asked only when the user has actually chosen to record — never at launch.
            var status = await recorder.authorizationStatus()
            if status == .notDetermined {
                _ = await recorder.requestAuthorization()
                status = await recorder.authorizationStatus()
            }
            switch status {
            case .authorized:
                break
            case .denied, .notDetermined:
                phase = .failed(
                    "마이크 권한이 없어 녹음할 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 HAE.NA를 허용해주세요."
                )
                return
            case .restricted:
                phase = .failed("이 기기에서는 마이크 사용이 제한되어 있어 녹음할 수 없습니다.")
                return
            }

            phase = .preparing
            let destination: URL
            do {
                destination = try scratchStore.makeDestination(fileExtension: recorder.fileExtension)
            } catch {
                phase = .failed("녹음 파일을 만들 공간을 준비하지 못했습니다.")
                return
            }

            do {
                try await recorder.startRecording(to: destination)
            } catch let error as MeetingAudioRecorderError {
                scratchStore.remove(destination)
                phase = .failed(message(for: error))
                return
            } catch {
                scratchStore.remove(destination)
                phase = .failed("녹음을 시작하지 못했습니다.")
                return
            }

            scratchURL = destination
            elapsed = 0
            phase = .recording(startedAt: now())
        }
    }

    private func stopRecording() {
        guard case .recording = phase else {
            return
        }
        phase = .stopping

        Task {
            let recorded: RecordedAudio
            do {
                recorded = try await recorder.stopRecording()
            } catch let error as MeetingAudioRecorderError {
                discardScratchFile()
                phase = .failed(message(for: error))
                return
            } catch {
                discardScratchFile()
                phase = .failed("녹음을 마치지 못했습니다.")
                return
            }

            // The same validator the file-import path uses, so a recording cannot reach
            // transcription on terms an imported file would have been rejected on.
            do {
                let validated = try captureService.validate(fileURL: recorded.fileURL)
                phase = .recorded(validated)
            } catch let error as AudioMeetingCaptureError {
                discardScratchFile()
                phase = .failed(validationMessage(for: error))
            } catch {
                discardScratchFile()
                phase = .failed("녹음 파일을 사용할 수 없습니다.")
            }
        }
    }

    private func cancelRecording() {
        guard case .recording = phase else {
            return
        }
        phase = .stopping
        Task {
            await recorder.cancelRecording()
            discardScratchFile()
            elapsed = 0
            phase = .idle
        }
    }

    /// Best-effort and idempotent: every teardown path calls it, including ones that run after the
    /// recorder already removed the file itself.
    private func discardScratchFile() {
        if let scratchURL {
            scratchStore.remove(scratchURL)
        }
        scratchURL = nil
    }

    // MARK: - Copy

    private func message(for error: MeetingAudioRecorderError) -> String {
        switch error {
        case .permissionDenied:
            return "마이크 권한이 없어 녹음할 수 없습니다. 시스템 설정에서 HAE.NA의 마이크 접근을 허용해주세요."
        case .permissionRestricted:
            return "이 기기에서는 마이크 사용이 제한되어 있어 녹음할 수 없습니다."
        case .noInputDevice:
            return "사용할 수 있는 마이크를 찾지 못했습니다. 입력 장치를 연결한 뒤 다시 시도해주세요."
        case .startFailed:
            return "녹음을 시작하지 못했습니다. 다른 앱이 마이크를 사용 중인지 확인해주세요."
        case .alreadyRecording:
            return "이미 녹음 중입니다."
        case .notRecording:
            return "진행 중인 녹음이 없습니다."
        case .interrupted:
            return "녹음이 중단되었습니다. 다시 시도해주세요."
        case .noAudioCaptured:
            return "녹음된 음성이 없습니다. 조금 더 길게 녹음해주세요."
        case .fileWriteFailed:
            return "녹음 파일을 저장하지 못했습니다."
        }
    }

    private func validationMessage(for error: AudioMeetingCaptureError) -> String {
        guard case .invalidFile(let reason) = error else {
            return "녹음 파일을 사용할 수 없습니다."
        }
        switch reason {
        case .emptyFile:
            return "녹음된 음성이 없습니다. 조금 더 길게 녹음해주세요."
        case .fileTooLarge:
            return "녹음이 너무 깁니다. 더 짧게 나눠 녹음해주세요."
        case .fileNotFound, .notReadable, .unsupportedFormat:
            return "녹음 파일을 사용할 수 없습니다."
        }
    }
}
