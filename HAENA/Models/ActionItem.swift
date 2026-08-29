import Foundation

enum ActionItemStatus: String, Codable, Equatable, Sendable {
    case proposed
    case confirmed
    case inProgress
    case completed
    case cancelled
}

/// A task surfaced from a meeting. `assigneeID` (a `Participant.id`) and `dueDate` are optional
/// because a meeting frequently leaves either unstated — that ambiguity must stay visible rather
/// than being defaulted away.
struct ActionItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let meetingID: UUID
    var title: String
    var details: String?
    var assigneeID: UUID?
    var dueDate: Date?
    var status: ActionItemStatus
    var evidence: EvidenceReference?
    var confidence: Confidence
    /// Original AI assignee provenance. Nil for legacy and hand-entered items.
    ///
    /// This is intentionally independent of mutable `assigneeID`: a reviewer may correct the
    /// assignee without erasing what the model proposed or how that proposal was resolved.
    var proposedAssigneeAttribution: AssigneeAttribution? = nil
    let createdAt: Date
    var updatedAt: Date
}
