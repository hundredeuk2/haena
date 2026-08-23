import SwiftUI

private enum PastedTranscriptInputMode: String, CaseIterable, Identifiable {
    case freeform
    case structured

    var id: Self { self }

    var label: String {
        switch self {
        case .freeform: return "자유 형식"
        case .structured: return "화자 구조화"
        }
    }
}

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
    @State private var inputMode = PastedTranscriptInputMode.freeform
    @State private var participantCandidates: [PastedParticipantNameCandidate] = []
    @State private var participantDrafts: [PastedParticipantDraft] = []
    @State private var newParticipantName = ""
    @State private var structuredTurns: [PastedTranscriptTurnDraft] = [
        PastedTranscriptTurnDraft(
            id: UUID(),
            text: "",
            sourceSpeakerLabel: "",
            selectedParticipantDraftID: nil
        )
    ]
    /// Missing key means deliberately unlinked. Keys preserve the exact user-authored source
    /// labels; values are draft IDs, never stored Participant IDs.
    @State private var speakerLinks: [String: UUID] = [:]
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
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("텍스트 회의록 붙여넣기")
                            .font(.title2)
                            .bold()

                        TextField("회의 제목", text: $meetingTitle)
                            .accessibilityIdentifier("meeting-title-field")

                        projectSection

                        Picker("입력 방식", selection: $inputMode) {
                            ForEach(PastedTranscriptInputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("pasted-transcript-input-mode-picker")

                        if inputMode == .freeform {
                            TextEditor(text: $transcriptText)
                                .frame(minHeight: 160)
                                .accessibilityIdentifier("transcript-text-editor")
                        } else {
                            structuredTranscriptSection
                        }

                        if let validationMessage {
                            Text(validationMessage)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("text-meeting-validation-message")
                        }

                        if isExtracting {
                            ProgressView("AI 분석 중…")
                                .accessibilityIdentifier("work-state-extraction-progress")
                        }
                    }
                    .padding(24)
                }
                .accessibilityIdentifier("paste-transcript-scroll")

                Divider()

                HStack {
                    if inputMode == .structured {
                        Button("발언 입력") {
                            scrollProxy.scrollTo("pasted-turns", anchor: .top)
                        }
                        .accessibilityIdentifier("show-pasted-turns-button")
                        .keyboardShortcut("t", modifiers: [.command, .option])

                        Button("화자 연결 확인") {
                            scrollProxy.scrollTo("pasted-speaker-linking", anchor: .top)
                        }
                        .accessibilityIdentifier("show-pasted-speaker-links-button")
                        .keyboardShortcut("l", modifiers: [.command, .option])
                    }

                    Spacer()

                    Button("취소") {
                        dismiss()
                    }
                    .accessibilityIdentifier("cancel-text-meeting-button")

                    Button("저장") {
                        saveMeeting()
                    }
                    .accessibilityIdentifier("save-text-meeting-button")
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(24)
            }
        }
        .frame(width: 700, height: 700)
        .task {
            do {
                projects = try await service.allProjects()
            } catch {
                validationMessage = "프로젝트를 불러오지 못했습니다."
            }
        }
        .onChange(of: selectedProjectID) { _, projectID in
            Task { await loadParticipantCandidates(projectID: projectID) }
        }
    }

    private var structuredTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("참석자 명부") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("새 참석자 이름", text: $newParticipantName)
                            .accessibilityIdentifier("pasted-participant-name-field")
                            .onSubmit { addUserEnteredParticipant() }
                        Button("추가") { addUserEnteredParticipant() }
                            .accessibilityIdentifier("add-pasted-participant-button")
                    }

                    if !participantCandidates.isEmpty {
                        Text("이 프로젝트의 이전 회의 이름 후보")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(participantCandidates.enumerated()), id: \.element.id) { index, candidate in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.displayName)
                                    Text(candidateDescription(candidate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("명부에 추가") { addCandidate(candidate) }
                                    .accessibilityIdentifier("add-pasted-candidate-\(index)")
                            }
                        }
                    }

                    if participantDrafts.isEmpty {
                        Text("참석자를 추가해도 화자 연결은 자동으로 이루어지지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(participantDrafts.enumerated()), id: \.element.id) { index, participant in
                            HStack {
                                Text("\(index + 1). \(participant.displayName)")
                                Text(participant.provenance == .userEntered ? "직접 입력" : "후보 직접 선택")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("제거") { removeParticipant(participant.id) }
                                    .accessibilityIdentifier("remove-pasted-participant-\(index)")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("화자 라벨 연결") {
                VStack(alignment: .leading, spacing: 8) {
                    if structuredSpeakerLabels.isEmpty {
                        Text("발언 블록에 라벨을 입력하면 연결 항목이 나타납니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(structuredSpeakerLabels.enumerated()), id: \.element) { index, label in
                        Picker(label, selection: speakerLinkBinding(for: label)) {
                            Text("미연결").tag(UUID?.none)
                            ForEach(participantDrafts) { participant in
                                Text(participant.displayName).tag(Optional(participant.id))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityIdentifier("pasted-speaker-link-picker-\(index)")
                    }
                }
                .padding(.vertical, 4)
            }
            .id("pasted-speaker-linking")

            GroupBox("저장 전 연결 미리보기") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(structuredSpeakerLabels, id: \.self) { label in
                        Text("\(label) → \(participantName(for: speakerLinks[label]) ?? "미연결")")
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("pasted-speaker-link-preview")
            }

            GroupBox("발언 블록") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(structuredTurns.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("정확한 화자 라벨", text: $structuredTurns[index].sourceSpeakerLabel)
                                    .accessibilityIdentifier("pasted-speaker-label-field-\(index)")
                                if structuredTurns.count > 1 {
                                    Button("블록 제거") { structuredTurns.remove(at: index) }
                                        .accessibilityIdentifier("remove-pasted-turn-\(index)")
                                }
                            }
                            TextEditor(text: $structuredTurns[index].text)
                                .frame(minHeight: 80)
                                .accessibilityIdentifier("pasted-turn-text-editor-\(index)")
                        }
                    }

                    Button("발언 블록 추가") { addTurn() }
                        .accessibilityIdentifier("add-pasted-turn-button")
                        .keyboardShortcut("n", modifiers: [.command, .option])
                }
                .padding(.vertical, 4)
            }
            .id("pasted-turns")
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
                        .onSubmit { createProject() }

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

    private var structuredSpeakerLabels: [String] {
        var seen: Set<String> = []
        return structuredTurns.compactMap { turn in
            guard !turn.sourceSpeakerLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
                seen.insert(turn.sourceSpeakerLabel).inserted else {
                return nil
            }
            return turn.sourceSpeakerLabel
        }
    }

    private func loadParticipantCandidates(projectID: UUID?) async {
        do {
            participantCandidates = try await service.participantNameCandidates(projectID: projectID)
        } catch {
            participantCandidates = []
            validationMessage = "참석자 후보를 불러오지 못했습니다."
        }
    }

    private func addUserEnteredParticipant() {
        let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationMessage = "참석자 이름을 입력해주세요."
            return
        }
        participantDrafts.append(
            PastedParticipantDraft(id: UUID(), displayName: name, provenance: .userEntered)
        )
        newParticipantName = ""
        validationMessage = nil
    }

    private func addCandidate(_ candidate: PastedParticipantNameCandidate) {
        participantDrafts.append(
            PastedParticipantDraft(
                id: UUID(),
                displayName: candidate.displayName,
                provenance: .selectedProjectNameCandidate
            )
        )
        validationMessage = nil
    }

    private func removeParticipant(_ id: UUID) {
        participantDrafts.removeAll { $0.id == id }
        speakerLinks = speakerLinks.filter { $0.value != id }
    }

    private func addTurn() {
        structuredTurns.append(
            PastedTranscriptTurnDraft(
                id: UUID(),
                text: "",
                sourceSpeakerLabel: "",
                selectedParticipantDraftID: nil
            )
        )
    }

    private func speakerLinkBinding(for label: String) -> Binding<UUID?> {
        Binding(
            get: { speakerLinks[label] },
            set: { selectedID in
                if let selectedID {
                    speakerLinks[label] = selectedID
                } else {
                    speakerLinks.removeValue(forKey: label)
                }
            }
        )
    }

    private func participantName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return participantDrafts.first(where: { $0.id == id })?.displayName
    }

    private func candidateDescription(_ candidate: PastedParticipantNameCandidate) -> String {
        if let label = candidate.sourceSpeakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return "\(candidate.meetingTitle) · \(label)"
        }
        return candidate.meetingTitle
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
                if inputMode == .freeform {
                    meeting = try await service.saveTextMeeting(
                        projectID: selectedProjectID,
                        title: meetingTitle,
                        transcript: transcriptText
                    )
                } else {
                    let turns = structuredTurns.map { turn in
                        return PastedTranscriptTurnDraft(
                            id: turn.id,
                            text: turn.text,
                            sourceSpeakerLabel: turn.sourceSpeakerLabel,
                            selectedParticipantDraftID: speakerLinks[turn.sourceSpeakerLabel]
                        )
                    }
                    meeting = try await service.saveTextMeeting(
                        projectID: selectedProjectID,
                        title: meetingTitle,
                        draft: PastedTranscriptDraft(
                            participants: participantDrafts,
                            turns: turns
                        )
                    )
                }
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
        case .participantNameMissing:
            return "참석자 이름을 입력해주세요."
        case .transcriptTurnMissing:
            return "모든 발언 블록에 원문을 입력해주세요."
        case .sourceSpeakerLabelMissing:
            return "모든 발언 블록에 정확한 화자 라벨을 입력해주세요."
        case .unknownParticipantDraft:
            return "화자 연결이 현재 참석자 명부를 참조하지 않습니다."
        case .duplicateParticipantDraftID:
            return "참석자 명부 식별자가 중복되었습니다."
        case .inconsistentSpeakerLink:
            return "같은 화자 라벨은 한 참석자 또는 미연결 상태로 통일해주세요."
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
