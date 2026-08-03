import Foundation

/// Internal failure reasons for pasted-text meeting capture. Kept separate from any
/// user-facing Korean copy so the service stays presentation-agnostic and unit-testable.
enum TextMeetingCaptureError: Error, Equatable, Sendable {
    case noProjectSelected
    case projectNameMissing
    case meetingTitleMissing
    case transcriptMissing
    case projectNotFound
}

/// Turns a pasted meeting transcript into a `Meeting` + single `TranscriptSegment`, attaches it
/// to the selected `Project`, and persists the result. Keeps model construction, validation, and
/// repository access out of the View layer so this flow is unit-testable without SwiftUI.
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

    func allProjects() async -> [Project] {
        await repository.allProjects()
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
        await repository.save(project)
        return project
    }

    /// Validates the inputs, builds a `.pastedText` `Meeting` with exactly one `TranscriptSegment`
    /// holding the full pasted body, appends it to the selected project, and saves the project.
    @discardableResult
    func saveTextMeeting(projectID: UUID?, title: String, transcript: String) async throws -> Meeting {
        guard let projectID else {
            throw TextMeetingCaptureError.noProjectSelected
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TextMeetingCaptureError.meetingTitleMissing
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw TextMeetingCaptureError.transcriptMissing
        }

        guard var project = await repository.project(id: projectID) else {
            throw TextMeetingCaptureError.projectNotFound
        }

        let timestamp = now()
        let meetingID = makeID()
        let segment = TranscriptSegment(
            id: makeID(),
            meetingID: meetingID,
            speakerID: nil,
            text: trimmedTranscript,
            startTime: nil,
            endTime: nil
        )
        let meeting = Meeting(
            id: meetingID,
            projectID: projectID,
            title: trimmedTitle,
            occurredAt: timestamp,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [segment],
            createdAt: timestamp
        )

        project.meetings.append(meeting)
        project.updatedAt = timestamp
        await repository.save(project)

        return meeting
    }
}
