import SwiftUI

/// Lets a user pick or create a project, paste a meeting transcript, save it as a `.pastedText`
/// Meeting, and then run work-state extraction over what was saved. Delegates every
/// model/repository/network operation to its two services — this view only holds UI state and maps
/// service errors to Korean copy, and never talks to a provider or to `URLSession` itself.
struct PasteTranscriptView: View {
    let service: TextMeetingCaptureService
    let extractionService: WorkStateExtractionService
    /// Asked for by the completion screen. The caller records where to go and this sheet closes
    /// itself; nothing here presents the browser.
    var onOpenResults: ((CaptureDestination) -> Void)?
    /// Optional and nil by default, so previews and existing call sites are unaffected. Nothing on
    /// this screen changes when it is absent.
    var metrics: BetaMetricsService?

    @Environment(\.dismiss) private var dismiss

    @State private var projects: [Project] = []
    @State private var selectedProjectID: UUID?
    @State private var isAddingNewProject = false
    @State private var newProjectName = ""
    @State private var meetingTitle = ""
    @State private var transcriptText = ""
    @State private var validationMessage: String?
    @State private var isExtracting = false
    /// Set once the meeting is safely stored, which is what replaces this form with the completion
    /// screen. Never set for a capture that failed before the save — there would be no meeting to
    /// report or to open.
    @State private var outcome: CaptureOutcome?

    var body: some View {
        if let outcome {
            CaptureCompletionView(
                outcome: outcome,
                identifiers: .pastedText,
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
            Text("텍스트 회의록 붙여넣기")
                .font(.title2)
                .bold()

            TextField("회의 제목", text: $meetingTitle)
                .accessibilityIdentifier("meeting-title-field")

            TextEditor(text: $transcriptText)
                .frame(minHeight: 160)
                .accessibilityIdentifier("transcript-text-editor")

            projectSection

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("text-meeting-validation-message")
            }

            if isExtracting {
                ProgressView("AI 분석 중…")
                    .accessibilityIdentifier("work-state-extraction-progress")
            }

            HStack {
                Button("취소") {
                    dismiss()
                }
                .accessibilityIdentifier("cancel-text-meeting-button")

                Spacer()

                Button("저장") {
                    saveMeeting()
                }
                .accessibilityIdentifier("save-text-meeting-button")
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 420)
        .task {
            do {
                projects = try await service.allProjects()
            } catch {
                validationMessage = "프로젝트를 불러오지 못했습니다."
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("프로젝트", selection: $selectedProjectID) {
                Text("선택 안 함").tag(UUID?.none)
                ForEach(projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .accessibilityIdentifier("project-picker")

            Button("새 프로젝트") {
                isAddingNewProject = true
            }
            .accessibilityIdentifier("new-project-button")

            if isAddingNewProject {
                HStack {
                    TextField("새 프로젝트 이름", text: $newProjectName)
                        .accessibilityIdentifier("new-project-name-field")

                    Button("만들기") {
                        createProject()
                    }
                    .accessibilityIdentifier("create-project-button")
                }
            }
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
            } catch let error as TextMeetingCaptureError {
                validationMessage = message(for: error)
            } catch {
                validationMessage = "프로젝트를 저장하지 못했습니다."
            }
        }
    }

    private func saveMeeting() {
        validationMessage = nil
        // The flow starts here — the moment the user pressed 저장 — not at the first await, so
        // validation and the repository read are inside the measure the same way they are inside
        // the user's wait.
        let run = CaptureRun(source: .pastedText, metrics: metrics)
        Task {
            let meeting: Meeting
            do {
                meeting = try await service.saveTextMeeting(
                    projectID: selectedProjectID,
                    title: meetingTitle,
                    transcript: transcriptText
                )
            } catch let error as TextMeetingCaptureError {
                validationMessage = message(for: error)
                await run.recordFailure()
                return
            } catch {
                validationMessage = "회의록을 저장하지 못했습니다."
                await run.recordFailure()
                return
            }

            // The transcript is already safely persisted at this point. Extraction runs after,
            // as a separate step whose failure is reported but never rolls the save back.
            let notice = await runExtraction(for: meeting)
            let completed = await CaptureOutcome.make(
                for: meeting,
                notice: notice,
                repository: service.repository
            )
            // The screen is handed the result first; measuring waits its turn behind it.
            outcome = completed
            await run.recordSuccess(completed)
        }
    }

    /// Returns the non-blocking notice to carry onto the completion screen, or nil when extraction
    /// did what it was asked to. A failure here never undoes the save, so it is reported beside the
    /// meeting rather than instead of it.
    private func runExtraction(for meeting: Meeting) async -> String? {
        isExtracting = true
        defer { isExtracting = false }

        do {
            try await extractionService.extractAndApply(
                meetingID: meeting.id,
                projectID: meeting.projectID
            )
            return nil
        } catch {
            return extractionFailureMessage(for: error)
        }
    }

    /// Maps extraction failures to fixed Korean copy. Nothing from the provider's response is
    /// interpolated, so no key material or transcript text can reach the screen through an error.
    private func extractionFailureMessage(for error: any Error) -> String {
        CaptureFailureCopy.extraction(error)
    }

    private func message(for error: TextMeetingCaptureError) -> String {
        switch error {
        case .noProjectSelected:
            return "프로젝트를 선택하거나 새로 만들어주세요."
        case .projectNameMissing:
            return "프로젝트 이름을 입력해주세요."
        case .meetingTitleMissing:
            return "회의 제목을 입력해주세요."
        case .transcriptMissing:
            return "회의록 본문을 입력해주세요."
        case .projectNotFound:
            return "선택한 프로젝트를 찾을 수 없습니다."
        }
    }
}

#Preview {
    let repository = InMemoryProjectRepository()
    return PasteTranscriptView(
        service: TextMeetingCaptureService(repository: repository),
        extractionService: WorkStateExtractionService(
            repository: repository,
            extractor: DeterministicWorkStateExtractor()
        )
    )
}
