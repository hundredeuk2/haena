import Foundation

/// Internal failure reasons for pasted-text meeting capture. Kept separate from any
/// user-facing Korean copy so the service stays presentation-agnostic and unit-testable.
enum TextMeetingCaptureError: Error, Equatable, Sendable {
    case noProjectSelected
    case projectNameMissing
    case meetingTitleMissing
    case transcriptMissing
    case projectNotFound
    case participantNameMissing
    case transcriptTurnMissing
    case sourceSpeakerLabelMissing
    case unknownParticipantDraft
    case duplicateParticipantDraftID
    case inconsistentSpeakerLink
}

/// Turns either a legacy free-form body or an explicitly structured pasted transcript into one
/// canonical `Meeting`, attaches it to the selected `Project`, and persists the result. No text
/// parser or name matcher participates in this service.
///
/// `now`/`makeID` are injected (defaulting to `Date.init`/`UUID.init`) so tests can supply fixed
/// values instead of depending on wall-clock time or random UUIDs.
struct TextMeetingCaptureService: Sendable {
    let repository: any ProjectRepository
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        repository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    func allProjects() async throws -> [Project] {
        try await repository.allProjects()
    }

    /// Returns every prior roster occurrence in the selected project. Duplicate names remain
    /// separate candidates so the UI cannot silently choose one, and selecting one later copies
    /// only its display name into a meeting-scoped draft.
    func participantNameCandidates(projectID: UUID?) async throws -> [PastedParticipantNameCandidate] {
        guard let projectID else {
            return []
        }
        guard let project = try await repository.project(id: projectID) else {
            throw TextMeetingCaptureError.projectNotFound
        }

        return project.meetings.flatMap { meeting in
            meeting.participants.map { participant in
                PastedParticipantNameCandidate(
                    id: .init(meetingID: meeting.id, participantID: participant.id),
                    displayName: participant.displayName,
                    meetingTitle: meeting.title,
                    sourceSpeakerLabel: participant.speakerLabel
                )
            }
        }
    }

    /// Creates and persists a new project. Project names are not required to be unique —
    /// identity is the UUID, not the name — so duplicate names are simply allowed.
    @discardableResult
    func createProject(name: String) async throws -> Project {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TextMeetingCaptureError.projectNameMissing
        }

        let timestamp = now()
        let project = Project(
            id: makeID(),
            name: trimmedName,
            summary: "",
            createdAt: timestamp,
            updatedAt: timestamp,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
        try await repository.save(project)
        return project
    }

    /// Validates the inputs, builds a `.pastedText` `Meeting` with exactly one `TranscriptSegment`
    /// holding the full pasted body, appends it to the selected project, and saves the project.
    @discardableResult
    func saveTextMeeting(projectID: UUID?, title: String, transcript: String,
                         onProgress: (@MainActor @Sendable (CaptureProgressPhase) -> Void)? = nil) async throws -> Meeting {
        let draft = PastedTranscriptDraft(
            participants: [],
            turns: [
                PastedTranscriptTurnDraft(
                    id: UUID(),
                    text: transcript,
                    sourceSpeakerLabel: "",
                    selectedParticipantDraftID: nil
                )
            ]
        )
        return try await save(
            projectID: projectID,
            title: title,
            draft: draft,
            allowsUnlabeledSingleTurn: true,
            onProgress: onProgress
        )
    }

    /// Saves only user-authored blocks and explicit roster links. Repeated source labels must have
    /// one consistent link (including consistently unlinked) across the entire draft.
    @discardableResult
    func saveTextMeeting(
        projectID: UUID?,
        title: String,
        draft: PastedTranscriptDraft,
        onProgress: (@MainActor @Sendable (CaptureProgressPhase) -> Void)? = nil
    ) async throws -> Meeting {
        try await save(
            projectID: projectID,
            title: title,
            draft: draft,
            allowsUnlabeledSingleTurn: false,
            onProgress: onProgress
        )
    }

    private func save(
        projectID: UUID?,
        title: String,
        draft: PastedTranscriptDraft,
        allowsUnlabeledSingleTurn: Bool,
        onProgress: (@MainActor @Sendable (CaptureProgressPhase) -> Void)?
    ) async throws -> Meeting {
        await onProgress?(.validating)
        guard let projectID else {
            throw TextMeetingCaptureError.noProjectSelected
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TextMeetingCaptureError.meetingTitleMissing
        }

        guard !draft.turns.isEmpty else {
            throw TextMeetingCaptureError.transcriptMissing
        }

        let participantIDs = draft.participants.map(\.id)
        guard Set(participantIDs).count == participantIDs.count else {
            throw TextMeetingCaptureError.duplicateParticipantDraftID
        }

        var participantNames: [UUID: String] = [:]
        for participant in draft.participants {
            let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw TextMeetingCaptureError.participantNameMissing
            }
            participantNames[participant.id] = name
        }

        struct ValidatedTurn {
            let text: String
            let sourceSpeakerLabel: String?
            let participantDraftID: UUID?
        }

        var validatedTurns: [ValidatedTurn] = []
        var linkBySourceLabel: [String: UUID?] = [:]
        for turn in draft.turns {
            let trimmedText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.isEmpty {
                throw allowsUnlabeledSingleTurn
                    ? TextMeetingCaptureError.transcriptMissing
                    : TextMeetingCaptureError.transcriptTurnMissing
            }

            let trimmedLabel = turn.sourceSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceLabel: String?
            if allowsUnlabeledSingleTurn && draft.turns.count == 1 && trimmedLabel.isEmpty {
                sourceLabel = nil
            } else {
                guard !trimmedLabel.isEmpty else {
                    throw TextMeetingCaptureError.sourceSpeakerLabelMissing
                }
                sourceLabel = turn.sourceSpeakerLabel
            }

            if let selectedID = turn.selectedParticipantDraftID,
               participantNames[selectedID] == nil {
                throw TextMeetingCaptureError.unknownParticipantDraft
            }

            if let sourceLabel {
                if let existing = linkBySourceLabel[sourceLabel] {
                    guard existing == turn.selectedParticipantDraftID else {
                        throw TextMeetingCaptureError.inconsistentSpeakerLink
                    }
                } else {
                    linkBySourceLabel.updateValue(
                        turn.selectedParticipantDraftID,
                        forKey: sourceLabel
                    )
                }
            }

            validatedTurns.append(
                ValidatedTurn(
                    text: allowsUnlabeledSingleTurn ? trimmedText : turn.text,
                    sourceSpeakerLabel: sourceLabel,
                    participantDraftID: turn.selectedParticipantDraftID
                )
            )
        }

        guard var project = try await repository.project(id: projectID) else {
            throw TextMeetingCaptureError.projectNotFound
        }

        let timestamp = now()
        let meetingID = makeID()
        var storedParticipantIDByDraftID: [UUID: UUID] = [:]
        let participants = draft.participants.map { participantDraft in
            let participantID = makeID()
            storedParticipantIDByDraftID[participantDraft.id] = participantID
            return Participant(
                id: participantID,
                displayName: participantNames[participantDraft.id]!,
                linkedUserID: nil,
                speakerLabel: nil
            )
        }
        let segments = validatedTurns.map { turn in
            TranscriptSegment(
                id: makeID(),
                meetingID: meetingID,
                speakerID: turn.participantDraftID.flatMap { storedParticipantIDByDraftID[$0] },
                sourceSpeakerLabel: turn.sourceSpeakerLabel,
                text: turn.text,
                startTime: nil,
                endTime: nil
            )
        }
        let meeting = Meeting(
            id: meetingID,
            projectID: projectID,
            title: trimmedTitle,
            occurredAt: timestamp,
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: segments,
            createdAt: timestamp
        )

        project.meetings.append(meeting)
        project.updatedAt = timestamp
        await onProgress?(.saving)
        try await repository.save(project)

        return meeting
    }
}
