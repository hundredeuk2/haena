import Foundation

/// A person appearing in a meeting. `linkedUserID` is nil until this participant is matched to
/// an account holder, so participants without an app account can still be recorded and assigned work.
struct Participant: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var linkedUserID: UUID?
    var speakerLabel: String?
}
