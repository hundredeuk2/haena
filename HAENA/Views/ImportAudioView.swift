import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets a user pick an audio file, attach it to a project, transcribe it, and run work-state
/// extraction over the result. Mirrors `PasteTranscriptView`: this view holds UI state and maps
/// service errors to Korean copy, and never talks to a provider or to `URLSession` itself.
struct ImportAudioView: View {
    let service: AudioMeetingCaptureService
    let extractionService: WorkStateExtractionService
    /// Set when the audio was already produced elsewhere — a finished microphone recording — in
    /// which case the file picker is replaced by a read-only summary and everything else about
    /// this screen is unchanged.
    var preselectedFile: ValidatedAudioFile?
    var sourceType: MeetingSourceType = .audioFile
    var heading: String = "오디오 파일 불러오기"
    /// Called once the audio has been handed to the capture service successfully, so the owner of
    /// a temporary recording knows it is safe to delete.
    var onTranscribed: (() -> Void)?
    /// Asked for by the completion screen. The caller records where to go and this sheet closes
    /// itself; nothing here presents the browser.
    var onOpenResults: ((CaptureDestination) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// The whole flow is one linear progression, so it is modelled as one value rather than
    /// several independent booleans that could disagree with each other.
    private enum Phase: Equatable {
        case idle
        case transcribing
        case saving
        /// The meeting reached storage. Only ever built from a real saved meeting, so the
        /// completion screen can always offer it.
        case completed(CaptureOutcome)
        case failed(String)

        /// Both phases where work is in flight. Every control that could start a second run is
        /// disabled while this is true.
        var isBusy: Bool {
            self == .transcribing || self == .saving
        }
    }

    @State private var projects: [Project] = []
    @State private var selectedProjectID: UUID?
    @State private var isAddingNewProject = false
    @State private var newProjectName = ""
    @State private var meetingTitle = ""
    /// Seeded from `preselectedFile` on appear; `chooseFile()` is the only other writer.
    @State private var selectedFile: ValidatedAudioFile?
    @State private var validationMessage: String?
    @State private var phase: Phase = .idle

    var body: some View {
        if case .completed(let outcome) = phase {
            CaptureCompletionView(
                outcome: outcome,
                identifiers: .audio,
                onOpenResults: {
                    onOpenResults?(outcome.destination)
                    dismiss()
                },
                onClose: { dismiss() }
            )
        } else {
            captureForm
        }
    }

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.title2)
                .bold()

            TextField("회의 제목", text: $meetingTitle)
                .accessibilityIdentifier("audio-meeting-title-field")
                .disabled(phase.isBusy)

            fileSection
            projectSection

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("audio-import-validation-message")
            }

            phaseSection

            HStack {
                Button("닫기") {
                    dismiss()
                }
                .accessibilityIdentifier("cancel-audio-import-button")
                .disabled(phase.isBusy)

                Spacer()

                Button("전사 시작") {
                    importAudio()
                }
                .accessibilityIdentifier("start-audio-import-button")
                // Guards against a second run being started while one is in flight, and against
                // starting one at all before a file has passed validation.
                .disabled(phase.isBusy || selectedFile == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 460)
        .task {
            if let preselectedFile {
                selectedFile = preselectedFile
                if meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meetingTitle = defaultRecordingTitle()
                }
            }
            do {
                projects = try await service.allProjects()
            } catch {
                validationMessage = "프로젝트를 불러오지 못했습니다."
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A recording is already chosen; offering a file picker here would let the user
            // silently swap it for something else and orphan the recording.
            if preselectedFile == nil {
                Button("오디오 파일 선택") {
                    chooseFile()
                }
                .accessibilityIdentifier("choose-audio-file-button")
                .disabled(phase.isBusy)
            }

            if let selectedFile {
                Text("\(selectedFile.fileName) · \(byteCountText(selectedFile.byteSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selected-audio-file-label")
            } else {
                Text("지원 형식: mp3, mp4, mpeg, mpga, m4a, wav, webm · 최대 25MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A recording has no filename the user chose, so the date stands in — better than an empty
    /// field they must fill before the button becomes usable.
    private func defaultRecordingTitle() -> String {
        "\(MeetingDateFormatter().string(from: Date())) 녹음"
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("프로젝트", selection: $selectedProjectID) {
                Text("선택 안 함").tag(UUID?.none)
                ForEach(projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .accessibilityIdentifier("audio-project-picker")
            .disabled(phase.isBusy)

            Button("새 프로젝트") {
                isAddingNewProject = true
            }
            .accessibilityIdentifier("audio-new-project-button")
            .disabled(phase.isBusy)

            if isAddingNewProject {
                HStack {
                    TextField("새 프로젝트 이름", text: $newProjectName)
                        .accessibilityIdentifier("audio-new-project-name-field")

                    Button("만들기") {
                        createProject()
                    }
                    .accessibilityIdentifier("audio-create-project-button")
                    .disabled(phase.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var phaseSection: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .transcribing:
            ProgressView("음성을 전사하는 중… 회의 길이에 따라 몇 분이 걸릴 수 있습니다.")
                .accessibilityIdentifier("audio-transcribing-progress")
        case .saving:
            ProgressView("저장하고 AI가 분석하는 중…")
                .accessibilityIdentifier("audio-saving-progress")
        case .completed:
            // The whole screen is the completion view by then; see `body`.
            EmptyView()
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("audio-import-failed-message")
        }
    }

    // MARK: - Actions

    /// Validates as soon as the file is chosen, so an unusable file is reported immediately
    /// rather than after the user has filled in a title and pressed start.
    private func chooseFile() {
        validationMessage = nil
        phase = .idle

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = AudioFileValidator.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            selectedFile = try service.validate(fileURL: url)
            if meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meetingTitle = url.deletingPathExtension().lastPathComponent
            }
        } catch let error as AudioMeetingCaptureError {
            selectedFile = nil
            validationMessage = message(for: error)
        } catch {
            selectedFile = nil
            validationMessage = "파일을 확인하지 못했습니다."
        }
    }

    private func createProject() {
        validationMessage = nil
        Task {
            do {
                let project = try await service.createProject(name: newProjectName)
                projects.append(project)
                selectedProjectID = project.id
                newProjectName = ""
                isAddingNewProject = false
            } catch let error as AudioMeetingCaptureError {
                validationMessage = message(for: error)
            } catch {
                validationMessage = "프로젝트를 저장하지 못했습니다."
            }
        }
    }

    private func importAudio() {
        guard let selectedFile, !phase.isBusy else {
            return
        }
        validationMessage = nil
        phase = .transcribing

        Task {
            let meeting: Meeting
            do {
                meeting = try await service.importAudioMeeting(
                    projectID: selectedProjectID,
                    title: meetingTitle,
                    fileURL: selectedFile.url,
                    sourceType: sourceType
                )
            } catch let error as AudioMeetingCaptureError {
                phase = .failed(message(for: error))
                return
            } catch {
                phase = .failed("전사에 실패했습니다.")
                return
            }

            // The transcript is safely persisted at this point. Extraction runs after, as a
            // separate step whose failure is reported but never rolls the save back.
            //
            // Signalled here rather than after extraction: the capture service has already made
            // its own copy of the audio, so a temporary recording is redundant from this moment
            // even if extraction goes on to fail.
            onTranscribed?()
            phase = .saving
            await runExtraction(for: meeting)
        }
    }

    /// Runs extraction over the already-stored meeting, then reports what the meeting holds.
    ///
    /// A failure here is carried onto the completion screen as a notice rather than replacing it:
    /// the audio, the transcript and the meeting are all safely stored by this point, and hiding
    /// them behind an error would be a lie about what happened.
    private func runExtraction(for meeting: Meeting) async {
        var notice: String?
        do {
            try await extractionService.extractAndApply(
                meetingID: meeting.id,
                projectID: meeting.projectID
            )
        } catch {
            notice = CaptureFailureCopy.extraction(error)
        }

        phase = .completed(
            await CaptureOutcome.make(for: meeting, notice: notice, repository: service.repository)
        )
    }

    // MARK: - Copy

    /// Maps failures to fixed Korean copy. Nothing from the provider's response is interpolated,
    /// so no key material or transcript text can reach the screen through an error.
    private func message(for error: AudioMeetingCaptureError) -> String {
        switch error {
        case .noProjectSelected:
            return "프로젝트를 선택하거나 새로 만들어주세요."
        case .projectNameMissing:
            return "프로젝트 이름을 입력해주세요."
        case .meetingTitleMissing:
            return "회의 제목을 입력해주세요."
        case .projectNotFound:
            return "선택한 프로젝트를 찾을 수 없습니다."
        case .invalidFile(let reason):
            return message(for: reason)
        case .storageFailure:
            return "오디오 파일을 앱 저장 공간에 복사하지 못했습니다."
        case .transcriptionFailed(let reason):
            return message(for: reason)
        case .repositoryFailure:
            return "회의록을 저장하지 못했습니다."
        }
    }

    private func message(for error: AudioFileValidationError) -> String {
        switch error {
        case .fileNotFound:
            return "파일을 찾을 수 없습니다."
        case .notReadable:
            return "파일을 읽을 수 없습니다. 권한을 확인해주세요."
        case .unsupportedFormat(let fileExtension):
            let name = fileExtension.isEmpty ? "확장자 없음" : ".\(fileExtension)"
            return "지원하지 않는 형식입니다(\(name)). mp3, mp4, mpeg, mpga, m4a, wav, webm만 사용할 수 있습니다."
        case .emptyFile:
            return "빈 파일입니다."
        case .fileTooLarge(let byteSize, let limit):
            return "파일이 너무 큽니다(\(byteCountText(byteSize))). 최대 \(byteCountText(limit))까지 보낼 수 있습니다."
        }
    }

    /// The stored audio survives every one of these, so each message ends by saying so — the
    /// user needs to know a retry will not require finding the original file again.
    private func message(for error: TranscriptionError) -> String {
        let suffix = "오디오는 앱에 저장되어 있어 다시 시도할 수 있습니다."
        switch error {
        case .missingCredential:
            return "전사를 사용하려면 OPENAI_API_KEY 환경변수가 필요합니다. \(suffix)"
        case .unauthorized:
            return "전사 인증에 실패했습니다. \(suffix)"
        case .rateLimited:
            return "전사 요청이 일시적으로 제한되었습니다. 잠시 후 다시 시도해주세요. \(suffix)"
        case .timedOut, .networkUnavailable:
            return "전사 서버에 연결하지 못했습니다. \(suffix)"
        case .emptyTranscript:
            return "전사 결과가 비어 있습니다. 음성이 들어 있는 파일인지 확인해주세요. \(suffix)"
        case .serverError, .requestRejected, .malformedResponse, .invalidConfiguration:
            return "전사에 실패했습니다. \(suffix)"
        }
    }

    private func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
