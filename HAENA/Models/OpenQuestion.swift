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
    /// When a user reviewed this question, or nil while it is still an unreviewed AI proposal.
    ///
    /// Unlike Decision and ActionItem, `OpenQuestionStatus` has no `.proposed` case — an approved
    /// question and a freshly extracted one are both `.open`. Without this marker the two are
    /// indistinguishable, and re-extracting the meeting would delete work the user had already
    /// accepted.
    var reviewedAt: Date? = nil
}
