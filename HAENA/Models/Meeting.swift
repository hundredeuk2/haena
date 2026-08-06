import Foundation

enum MeetingSourceType: String, Codable, Equatable, Sendable {
    case microphone
    case audioFile
    case videoFile
    case pastedText
}

/// A meeting or pasted meeting note that produced (or may produce) Decisions, ActionItems,
/// and OpenQuestions. Owns its participants and transcript; does not reference its parent
/// `Project` directly to avoid a Project <-> Meeting cycle — see `projectID` instead.
struct Meeting: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    var title: String
    var occurredAt: Date
    var sourceType: MeetingSourceType
    var participants: [Participant]
    var transcriptSegments: [TranscriptSegment]
    let createdAt: Date
    /// The app's stored copy of the imported audio, for `.audioFile` meetings.
    ///
    /// Optional rather than a separate schema version: `Codable` decodes a missing key for an
    /// optional property as nil, so meetings written before audio import existed keep loading
    /// unchanged and `ProjectStoreFile.currentSchemaVersion` stays at 1.
    var audioAsset: AudioAsset?

    init(
        id: UUID,
        projectID: UUID,
        title: String,
        occurredAt: Date,
        sourceType: MeetingSourceType,
        participants: [Participant],
        transcriptSegments: [TranscriptSegment],
        createdAt: Date,
        audioAsset: AudioAsset? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.occurredAt = occurredAt
        self.sourceType = sourceType
        self.participants = participants
        self.transcriptSegments = transcriptSegments
        self.createdAt = createdAt
        self.audioAsset = audioAsset
    }
}
