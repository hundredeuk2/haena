import Foundation

/// Internal failure reasons for speaker confirmation. Kept separate from user-facing Korean copy
/// so the service stays presentation-agnostic and unit-testable.
enum SpeakerConfirmationError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    /// The given id is not a diarized speaker of this meeting.
    case speakerNotFound
    case participantNotFound
    case nameMissing
    case repositoryFailure
}

/// One line of transcript shown to help the user recognise a voice. Verbatim: never summarised,
/// truncated, or reordered, because the point is to let the user hear the meeting in their head.
struct RepresentativeUtterance: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval?
}

/// A diarized voice awaiting identification, with enough context to recognise it.
struct UnconfirmedSpeaker: Equatable, Sendable, Identifiable {
    /// The anonymous `Participant.id` the meeting's segments point at.
    let id: UUID
    let displayName: String
    let providerSpeakerLabel: String?
    let utteranceCount: Int
    let representativeUtterances: [RepresentativeUtterance]
}

/// A person the user can link a voice to.
struct SpeakerCandidate: Equatable, Sendable, Identifiable {
    /// Set when this person already exists in **this** meeting, which is also how two voices get
    /// linked to one person. Nil when the name is only known from another meeting in the project,
    /// in which case choosing it creates a fresh participant here rather than sharing an identity
    /// across meetings.
    let existingParticipantID: UUID?
    let displayName: String

    var id: String {
        existingParticipantID?.uuidString ?? "name:\(displayName)"
    }
}

/// What the confirmation screen needs to render, read in one pass.
struct SpeakerConfirmationOverview: Equatable, Sendable {
    let unconfirmed: [UnconfirmedSpeaker]
    let candidates: [SpeakerCandidate]
}

/// Links diarized voices to people, after the fact.
///
/// Every operation reads the project, mutates only `Meeting.participants` and
/// `Meeting.speakerResolutions`, saves, and re-reads — callers render what was actually persisted
/// rather than an optimistic guess. Transcript text, timings, evidence, and the content or status
/// of any Decision/ActionItem/OpenQuestion/AgendaItem are never touched.
struct SpeakerConfirmationService: Sendable {
    let repository: any ProjectRepository
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    /// Utterances shorter than this are treated as filler ("네.", "맞아요") and only used to fill
    /// out the sample when nothing more substantial exists.
    private static let substantialUtteranceLength = 10
    private static let maximumRepresentativeUtterances = 3

    init(
        repository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    // MARK: - Reading

    func overview(projectID: UUID, meetingID: UUID) async throws -> SpeakerConfirmationOverview {
        let project = try await requireProject(projectID)
        let meeting = try requireMeeting(meetingID, in: project)
        return SpeakerConfirmationOverview(
            unconfirmed: Self.unconfirmedSpeakers(in: meeting),
            candidates: Self.candidates(for: meeting, in: project)
        )
    }

    static func unconfirmedSpeakers(in meeting: Meeting) -> [UnconfirmedSpeaker] {
        meeting.unconfirmedSpeakers.map { participant in
            let spoken = meeting.transcriptSegments.filter { $0.speakerID == participant.id }
            return UnconfirmedSpeaker(
                id: participant.id,
                displayName: participant.displayName,
                providerSpeakerLabel: participant.speakerLabel,
                utteranceCount: spoken.count,
                representativeUtterances: representativeUtterances(from: spoken)
            )
        }
    }

    /// Prefers utterances with enough words to recognise a person, tops up with shorter ones only
    /// when there are not enough, and always returns them in the order they were spoken.
    static func representativeUtterances(
        from segments: [TranscriptSegment]
    ) -> [RepresentativeUtterance] {
        let nonEmpty = segments.enumerated().filter {
            !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let substantial = nonEmpty.filter {
            $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= substantialUtteranceLength
        }
        let shorter = nonEmpty.filter {
            $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).count < substantialUtteranceLength
        }

        let chosen = (substantial + shorter).prefix(maximumRepresentativeUtterances)
        return chosen
            .sorted { $0.offset < $1.offset }
            .map { RepresentativeUtterance(text: $0.element.text, startTime: $0.element.startTime) }
    }

    /// People already confirmed in this meeting first — choosing one is how two voices become the
    /// same person — then names known elsewhere in the project, deduplicated by name.
    static func candidates(for meeting: Meeting, in project: Project) -> [SpeakerCandidate] {
        var result: [SpeakerCandidate] = []
        var seenNames: Set<String> = []

        for participant in meeting.assignableParticipants {
            let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenNames.insert(name).inserted else {
                continue
            }
            result.append(SpeakerCandidate(existingParticipantID: participant.id, displayName: name))
        }

        for other in project.meetings where other.id != meeting.id {
            for participant in other.assignableParticipants {
                let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                // Deliberately carries no id: a name matching across meetings is a suggestion, not
                // evidence that it is the same person, so choosing it creates a participant here.
                guard seenNames.insert(name).inserted else {
                    continue
                }
                result.append(SpeakerCandidate(existingParticipantID: nil, displayName: name))
            }
        }

        return result
    }

    // MARK: - Linking

    /// Links a voice to somebody already in this meeting. Two voices may point at one person.
    @discardableResult
    func link(
        speakerID: UUID,
        toExistingParticipant participantID: UUID,
        meetingID: UUID,
        projectID: UUID
    ) async throws -> Project {
        try await mutate(projectID: projectID, meetingID: meetingID) { meeting in
            let speaker = try Self.requireSpeaker(speakerID, in: meeting)
            guard meeting.participants.contains(where: { $0.id == participantID }) else {
                throw SpeakerConfirmationError.participantNotFound
            }
            Self.setResolution(
                in: &meeting,
                speaker: speaker,
                resolvedParticipantID: participantID
            )
        }
    }

    /// Creates a person in this meeting under the given name and links the voice to them.
    ///
    /// Never merges on a matching name: two people can share one, and silently attaching a voice
    /// to the wrong person is worse than an extra row the user can link themselves.
    @discardableResult
    func link(
        speakerID: UUID,
        toNewParticipantNamed name: String,
        meetingID: UUID,
        projectID: UUID
    ) async throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerConfirmationError.nameMissing
        }
        return try await mutate(projectID: projectID, meetingID: meetingID) { meeting in
            let speaker = try Self.requireSpeaker(speakerID, in: meeting)
            let participant = Participant(
                id: makeID(),
                displayName: trimmed,
                linkedUserID: nil,
                // Nil marks this as a person the user named, not a voice the provider separated.
                speakerLabel: nil
            )
            meeting.participants.append(participant)
            Self.setResolution(in: &meeting, speaker: speaker, resolvedParticipantID: participant.id)
        }
    }

    /// Returns a voice to its unconfirmed state. This is the undo for a wrong link, including one
    /// that merged two voices into a single person.
    @discardableResult
    func unlink(
        speakerID: UUID,
        meetingID: UUID,
        projectID: UUID
    ) async throws -> Project {
        try await mutate(projectID: projectID, meetingID: meetingID) { meeting in
            _ = try Self.requireSpeaker(speakerID, in: meeting)
            meeting.speakerResolutions.removeAll { $0.anonymousParticipantID == speakerID }
        }
    }

    // MARK: - Internals

    private static func requireSpeaker(_ speakerID: UUID, in meeting: Meeting) throws -> Participant {
        guard let speaker = meeting.diarizedSpeakers.first(where: { $0.id == speakerID }) else {
            throw SpeakerConfirmationError.speakerNotFound
        }
        return speaker
    }

    private static func setResolution(
        in meeting: inout Meeting,
        speaker: Participant,
        resolvedParticipantID: UUID
    ) {
        let resolution = SpeakerResolution(
            anonymousParticipantID: speaker.id,
            providerSpeakerLabel: speaker.speakerLabel,
            resolvedParticipantID: resolvedParticipantID
        )
        if let index = meeting.speakerResolutions.firstIndex(where: {
            $0.anonymousParticipantID == speaker.id
        }) {
            meeting.speakerResolutions[index] = resolution
        } else {
            meeting.speakerResolutions.append(resolution)
        }
    }

    /// Read, mutate one meeting, save, re-read. The reload is the point: the screen shows what the
    /// repository holds, so a save that silently failed cannot look like a success.
    private func mutate(
        projectID: UUID,
        meetingID: UUID,
        _ body: (inout Meeting) throws -> Void
    ) async throws -> Project {
        var project = try await requireProject(projectID)
        guard let index = project.meetings.firstIndex(where: { $0.id == meetingID }) else {
            throw SpeakerConfirmationError.meetingNotFound
        }

        var meeting = project.meetings[index]
        try body(&meeting)
        project.meetings[index] = meeting
        project.updatedAt = now()

        do {
            try await repository.save(project)
        } catch {
            throw SpeakerConfirmationError.repositoryFailure
        }
        return try await requireProject(projectID)
    }

    private func requireProject(_ projectID: UUID) async throws -> Project {
        let project: Project?
        do {
            project = try await repository.project(id: projectID)
        } catch {
            throw SpeakerConfirmationError.repositoryFailure
        }
        guard let project else {
            throw SpeakerConfirmationError.projectNotFound
        }
        return project
    }

    private func requireMeeting(_ meetingID: UUID, in project: Project) throws -> Meeting {
        guard let meeting = project.meetings.first(where: { $0.id == meetingID }) else {
            throw SpeakerConfirmationError.meetingNotFound
        }
        return meeting
    }
}
