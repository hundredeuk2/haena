import Foundation

/// Minimal lifecycle for a next-meeting agenda entry: not spelled out in the product spec,
/// kept to the smallest set that distinguishes "still needs discussion" from "handled".
enum AgendaItemStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
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
}
