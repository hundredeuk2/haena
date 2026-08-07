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
    /// Which diarized voices the user has confirmed as which people. Empty is the normal state:
    /// speaker confirmation is optional, and a meeting is fully usable without it.
    var speakerResolutions: [SpeakerResolution]

    init(
        id: UUID,
        projectID: UUID,
        title: String,
        occurredAt: Date,
        sourceType: MeetingSourceType,
        participants: [Participant],
        transcriptSegments: [TranscriptSegment],
        createdAt: Date,
        audioAsset: AudioAsset? = nil,
        speakerResolutions: [SpeakerResolution] = []
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
        self.speakerResolutions = speakerResolutions
    }

    /// Decoded by hand for one reason: `speakerResolutions` must default to empty when the key is
    /// absent. Synthesized decoding throws on a missing key for a non-optional property, which
    /// would make every meeting written before speaker confirmation existed unreadable. This keeps
    /// `ProjectStoreFile.currentSchemaVersion` at 1 and needs no migration.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = try container.decode(String.self, forKey: .title)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        sourceType = try container.decode(MeetingSourceType.self, forKey: .sourceType)
        participants = try container.decode([Participant].self, forKey: .participants)
        transcriptSegments = try container.decode([TranscriptSegment].self, forKey: .transcriptSegments)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        audioAsset = try container.decodeIfPresent(AudioAsset.self, forKey: .audioAsset)
        speakerResolutions = try container.decodeIfPresent(
            [SpeakerResolution].self,
            forKey: .speakerResolutions
        ) ?? []
    }
}
