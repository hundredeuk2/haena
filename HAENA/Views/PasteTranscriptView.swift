import SwiftUI

/// Lets a user pick or create a project, paste a meeting transcript, save it as a `.pastedText`
/// Meeting, and then run work-state extraction over what was saved. Delegates every
/// model/repository/network operation to its two services — this view only holds UI state and maps
/// service errors to Korean copy, and never talks to a provider or to `URLSession` itself.
struct PasteTranscriptView: View {
    let service: TextMeetingCaptureService
    let extractionService: WorkStateExtractionService

    @Environment(\.dismiss) private var dismiss

    @State private var projects: [Project] = []
    @State private var selectedProjectID: UUID?
    @State private var isAddingNewProject = false
    @State private var newProjectName = ""
    @State private var meetingTitle = ""
    @State private var transcriptText = ""
    @State private var validationMessage: String?
    @State private var savedMessage: String?
    @State private var extractionMessage: String?
    @State private var isExtracting = false

    var body: some View {
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

            if let savedMessage {
                Text(savedMessage)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("text-meeting-saved-message")
            }

            if isExtracting {
                ProgressView("AI 분석 중…")
                    .accessibilityIdentifier("work-state-extraction-progress")
            }

            if let extractionMessage {
                Text(extractionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("work-state-extraction-message")
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
        savedMessage = nil
        extractionMessage = nil
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
                return
            } catch {
                validationMessage = "회의록을 저장하지 못했습니다."
                return
            }

            // The transcript is already safely persisted at this point. Extraction runs after,
            // as a separate step whose failure is reported but never rolls the save back.
            savedMessage = "회의록이 저장되었습니다."
            await runExtraction(for: meeting)
        }
    }

    private func runExtraction(for meeting: Meeting) async {
        isExtracting = true
        defer { isExtracting = false }

        do {
            let report = try await extractionService.extractAndApply(
                meetingID: meeting.id,
                projectID: meeting.projectID
            )
            extractionMessage = report.storedCount == 0
                ? "AI가 근거를 확인할 수 있는 제안을 찾지 못했습니다."
                : "AI 제안 \(report.storedCount)건이 추가되었습니다. 검토·승인 전까지는 제안 상태입니다."
        } catch {
            extractionMessage = extractionFailureMessage(for: error)
        }
    }

    /// Maps extraction failures to fixed Korean copy. Nothing from the provider's response is
    /// interpolated, so no key material or transcript text can reach the screen through an error.
    private func extractionFailureMessage(for error: any Error) -> String {
        let suffix = "회의록은 저장되었습니다."
        guard let error = error as? WorkStateExtractionError else {
            return "AI 분석에 실패했습니다. \(suffix)"
        }

        switch error {
        case .missingCredential:
            return "AI 분석을 사용하려면 OPENAI_API_KEY 환경변수가 필요합니다. \(suffix)"
        case .unauthorized:
            return "AI 인증에 실패했습니다. \(suffix)"
        case .rateLimited:
            return "AI 요청이 일시적으로 제한되었습니다. 잠시 후 다시 시도해주세요. \(suffix)"
        case .timedOut, .networkUnavailable:
            return "AI 서버에 연결하지 못했습니다. \(suffix)"
        case .refused:
            return "AI가 이 회의록 분석을 거절했습니다. \(suffix)"
        case .serverError, .requestRejected, .emptyResponse, .malformedResponse, .invalidConfiguration:
            return "AI 분석에 실패했습니다. \(suffix)"
        }
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
