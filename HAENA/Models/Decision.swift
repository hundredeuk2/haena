import Foundation

enum DecisionStatus: String, Codable, Equatable, Sendable {
    case proposed
    case confirmed
    case superseded
    case rejected
}

/// A choice made (or proposed) in a meeting. `status` distinguishes an AI-suggested decision
/// (`.proposed`) from one a user has verified (`.confirmed`) — extraction logic must never
/// set `.confirmed` on its own, and should not do so without `evidence` present.
struct Decision: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let meetingID: UUID
    var statement: String
    var rationale: String?
    var status: DecisionStatus
    var evidence: EvidenceReference?
    var confidence: Confidence
    let createdAt: Date
    var updatedAt: Date
}
