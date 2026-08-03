import Foundation

/// The current, persistent work state of a single project — the aggregate root that owns
/// every meeting, decision, action item, open question, and upcoming agenda item derived from it.
struct Project: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    let createdAt: Date
    var updatedAt: Date
    var meetings: [Meeting]
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [OpenQuestion]
    var nextAgenda: [AgendaItem]
}
