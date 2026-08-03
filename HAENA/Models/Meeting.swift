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
}
