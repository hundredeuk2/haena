import Foundation

/// Who is using this copy of the app.
///
/// There is exactly one of these, it never leaves the machine, and it is not an account: no email,
/// no password, no organisation, no server id. HAE.NA is a local-first app for a single person, so
/// "the user" is whoever is sitting at this Mac — see the *Solo-first, Share-ready, Team-later*
/// decision. Deliberately not modelled as a collection of users: a list of one is an invitation to
/// grow an account system nobody asked for.
///
/// `linkedParticipantIDs` is what connects that person to the meetings they were in. A
/// `Participant` is meeting-scoped — the same human appears as a separate record in every meeting,
/// under whatever name that transcript used — so identifying yourself means naming several of them.
/// **Only ids the user confirmed themselves belong here.** Matching names is a guess, and a wrong
/// guess silently hands someone else's work to the user as their own.
struct LocalUserProfile: Codable, Equatable, Sendable {
    let id: UUID
    /// What the user calls themselves. Never derived from the system account, a transcript, or a
    /// participant name.
    private(set) var displayName: String
    /// Sorted and deduplicated, so the stored file is stable between saves and membership tests
    /// cannot depend on insertion order.
    private(set) var linkedParticipantIDs: [UUID]
    let createdAt: Date
    private(set) var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        linkedParticipantIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.linkedParticipantIDs = Self.normalised(linkedParticipantIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True once the user has both named themselves and pointed at at least one participant. Until
    /// then nothing can be called "mine" without inventing an answer.
    var isIdentified: Bool {
        !linkedParticipantIDs.isEmpty
    }

    func isLinked(_ participantID: UUID) -> Bool {
        linkedParticipantIDs.contains(participantID)
    }

    // MARK: - Editing

    /// Rejects a blank name rather than storing one: a profile whose name is whitespace would show
    /// as an empty row the user could not tell from a bug.
    static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func rename(to name: String, at timestamp: Date) -> Bool {
        guard let validated = Self.validatedName(name) else {
            return false
        }
        displayName = validated
        updatedAt = timestamp
        return true
    }

    mutating func link(_ participantIDs: [UUID], at timestamp: Date) {
        let updated = Self.normalised(linkedParticipantIDs + participantIDs)
        guard updated != linkedParticipantIDs else {
            return
        }
        linkedParticipantIDs = updated
        updatedAt = timestamp
    }

    mutating func unlink(_ participantID: UUID, at timestamp: Date) {
        guard linkedParticipantIDs.contains(participantID) else {
            return
        }
        linkedParticipantIDs.removeAll { $0 == participantID }
        updatedAt = timestamp
    }

    private static func normalised(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }
}
