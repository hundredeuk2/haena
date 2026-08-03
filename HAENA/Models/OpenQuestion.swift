import Foundation

enum OpenQuestionStatus: String, Codable, Equatable, Sendable {
    case open
    case resolved
    case dismissed
}

/// A question raised in a meeting that has no answer yet. Feeds into `AgendaItem` generation
/// for the next meeting until it moves to `.resolved` or `.dismissed`.
struct OpenQuestion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let meetingID: UUID
    var question: String
    var status: OpenQuestionStatus
    var evidence: EvidenceReference?
    var confidence: Confidence
    let createdAt: Date
    var resolvedAt: Date?
}
