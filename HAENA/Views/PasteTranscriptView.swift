import SwiftUI

/// Lets a user pick or create a project, paste a meeting transcript, and save it as a
/// `.pastedText` Meeting. Delegates every model/repository operation to `TextMeetingCaptureService`
/// — this view only holds UI state and maps service errors to Korean copy.
struct PasteTranscriptView: View {
    let service: TextMeetingCaptureService

    @Environment(\.dismiss) private var dismiss

    @State private var projects: [Project] = []
    @State private var selectedProjectID: UUID?
    @State private var isAddingNewProject = false
    @State private var newProjectName = ""
    @State private var meetingTitle = ""
    @State private var transcriptText = ""
    @State private var validationMessage: String?
    @State private var savedMessage: String?

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
            projects = await service.allProjects()
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
            } catch {
                validationMessage = message(for: error)
            }
        }
    }

    private func saveMeeting() {
        validationMessage = nil
        savedMessage = nil
        Task {
            do {
                try await service.saveTextMeeting(
                    projectID: selectedProjectID,
                    title: meetingTitle,
                    transcript: transcriptText
                )
                savedMessage = "회의록이 저장되었습니다."
            } catch {
                validationMessage = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        guard let captureError = error as? TextMeetingCaptureError else {
            return "알 수 없는 오류가 발생했습니다."
        }
        switch captureError {
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
    PasteTranscriptView(service: TextMeetingCaptureService(repository: InMemoryProjectRepository()))
}
