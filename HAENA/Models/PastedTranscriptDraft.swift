import Foundation

/// User-authored, meeting-scoped roster entry for a pasted transcript.
///
/// `id` exists only while composing the meeting. Saving always creates a fresh `Participant.id`,
/// so choosing a name seen in another meeting never shares that meeting's domain identity.
struct PastedParticipantDraft: Identifiable, Equatable, Sendable {
    enum Provenance: String, Equatable, Sendable {
        /// The user typed a new display name on the paste screen.
        case userEntered
        /// The user explicitly selected one occurrence from the selected project's prior roster.
        case selectedProjectNameCandidate
    }

    let id: UUID
    var displayName: String
    let provenance: Provenance
}

/// One explicitly authored utterance block. No delimiter, name, or sentence inference creates
/// these turns: the user supplies both the exact source label and the original text.
struct PastedTranscriptTurnDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var sourceSpeakerLabel: String
    /// References `PastedParticipantDraft.id`, never a stored `Participant.id`.
    var selectedParticipantDraftID: UUID?
}

/// Structured pasted-transcript input. The legacy free-form API remains a separate compatibility
/// path and stores one unlabeled, unlinked segment.
struct PastedTranscriptDraft: Equatable, Sendable {
    var participants: [PastedParticipantDraft]
    var turns: [PastedTranscriptTurnDraft]
}

/// One prior roster occurrence shown as an explicit name candidate. The source IDs disambiguate
/// duplicate names in the UI only and are never copied into a new meeting or sent to a provider.
struct PastedParticipantNameCandidate: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let meetingID: UUID
        let participantID: UUID
    }

    let id: ID
    let displayName: String
    let meetingTitle: String
    let sourceSpeakerLabel: String?
}
