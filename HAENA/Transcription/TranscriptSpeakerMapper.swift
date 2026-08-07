import Foundation

/// Turns a provider's opaque speaker labels into `Participant`s that are stable within one meeting.
///
/// Two rules matter here:
///
/// 1. **The same provider label always maps to the same `Participant`.** Labels are collected in
///    order of first appearance, so every segment spoken by `"speaker_1"` points at one identity
///    rather than a new one per segment.
/// 2. **Names are never guessed.** Display names are anonymous positional labels — `Speaker 1`,
///    `Speaker 2` — because no provider knows who is actually in the room, and putting a
///    plausible-looking real name on a transcript would be an invented fact the user has to
///    notice and undo. The provider's own label is kept in `speakerLabel` for traceability.
enum TranscriptSpeakerMapper {
    struct Mapping {
        let participants: [Participant]
        private let identifiersByLabel: [String: UUID]

        init(participants: [Participant], identifiersByLabel: [String: UUID]) {
            self.participants = participants
            self.identifiersByLabel = identifiersByLabel
        }

        /// Nil for a segment the provider gave no speaker for — a normal, expected value that
        /// becomes `TranscriptSegment.speakerID == nil`, never a fabricated participant.
        func participantID(forLabel label: String?) -> UUID? {
            guard let label else {
                return nil
            }
            return identifiersByLabel[label]
        }
    }

    static func map(
        _ segments: [TranscriptionSegment],
        makeID: () -> UUID
    ) -> Mapping {
        var identifiersByLabel: [String: UUID] = [:]
        var participants: [Participant] = []

        for segment in segments {
            guard let label = segment.speakerLabel, identifiersByLabel[label] == nil else {
                continue
            }
            let id = makeID()
            identifiersByLabel[label] = id
            participants.append(
                Participant(
                    id: id,
                    displayName: "Speaker \(participants.count + 1)",
                    linkedUserID: nil,
                    speakerLabel: label
                )
            )
        }

        return Mapping(participants: participants, identifiersByLabel: identifiersByLabel)
    }
}
