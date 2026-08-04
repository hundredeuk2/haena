import Foundation

/// Minimal lifecycle for a next-meeting agenda entry: not spelled out in the product spec,
/// kept to the smallest set that distinguishes "still needs discussion" from "handled".
enum AgendaItemStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
    /// The user decided this does not belong on the next agenda. Distinct from `.resolved`, which
    /// means it was actually dealt with.
    case dismissed
}

/// An entry on a project's next-meeting agenda. May originate from a past meeting, an
/// `ActionItem`, an `OpenQuestion`, none of them (user-added), or any combination — all three
/// linking fields are optional so an agenda item never requires manufacturing a source.
struct AgendaItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    var title: String
    var reason: String
    var sourceMeetingID: UUID?
    var relatedActionItemID: UUID?
    var relatedOpenQuestionID: UUID?
    var status: AgendaItemStatus
    let createdAt: Date
    /// Both nil for a user-added agenda item, and both set for one an extractor proposed — unlike
    /// Decision/ActionItem/OpenQuestion, an AgendaItem has always been allowed to originate from a
    /// person rather than a model, so neither field can be required. Their presence is what marks
    /// an entry as AI-derived and therefore still unreviewed.
    var evidence: EvidenceReference? = nil
    var confidence: Confidence? = nil
    /// When a user reviewed this item, or nil while it is still an unreviewed AI proposal. Needed
    /// for the same reason as `OpenQuestion.reviewedAt`: `.pending` alone cannot tell an approved
    /// agenda item apart from one the model just suggested.
    var reviewedAt: Date? = nil
}
