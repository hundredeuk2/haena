import Foundation

/// A user's confirmation that one diarized voice belongs to a particular person.
///
/// Stored as a mapping rather than by renaming the anonymous participant, because two different
/// diarized voices may turn out to be the same person. Re-pointing `TranscriptSegment.speakerID`
/// would merge them and destroy the provider's original separation; keeping the link beside the
/// segments preserves what the provider heard while still showing the user one name.
///
/// Lives inside `Meeting`, which makes the scoping structural: a confirmation cannot leak into
/// another meeting, and deleting a meeting or project takes its confirmations with it rather than
/// leaving orphans behind.
struct SpeakerResolution: Codable, Equatable, Sendable {
    /// The auto-created `Speaker N` participant that this meeting's segments point at.
    let anonymousParticipantID: UUID
    /// The provider's own label for that voice, kept only for traceability.
    let providerSpeakerLabel: String?
    /// The participant the user says this voice actually is. Also lives in `Meeting.participants`.
    var resolvedParticipantID: UUID
}

extension Meeting {
    /// Participants that came from provider diarization — they carry the provider's own
    /// `speakerLabel` — as opposed to people the user named themselves.
    var diarizedSpeakers: [Participant] {
        participants.filter { $0.speakerLabel != nil }
    }

    /// Diarized voices the user has not yet identified. A non-empty result is what the meeting
    /// screen offers to resolve; an empty one means there is nothing to ask about.
    var unconfirmedSpeakers: [Participant] {
        diarizedSpeakers.filter { participant in
            !speakerResolutions.contains { $0.anonymousParticipantID == participant.id }
        }
    }

    func resolution(forSpeakerID speakerID: UUID) -> SpeakerResolution? {
        speakerResolutions.first { $0.anonymousParticipantID == speakerID }
    }

    /// The person a stored participant id should be shown as: the confirmed person when that
    /// voice has been identified, otherwise the participant itself.
    func confirmedParticipant(for participantID: UUID) -> Participant? {
        guard let participant = participants.first(where: { $0.id == participantID }) else {
            return nil
        }
        guard let resolution = resolution(forSpeakerID: participantID),
              let resolved = participants.first(where: { $0.id == resolution.resolvedParticipantID }) else {
            return participant
        }
        return resolved
    }

    /// The roster used for **looking a name up by id**. Ids are preserved and only names are
    /// substituted, so a reference stored against an anonymous speaker — an `ActionItem.assigneeID`
    /// that resolved to `Speaker 1` before anyone was confirmed — keeps resolving, and starts
    /// showing the real name instead of silently becoming "미지정".
    var displayRoster: [Participant] {
        participants.map { participant in
            guard let confirmed = confirmedParticipant(for: participant.id),
                  confirmed.id != participant.id else {
                return participant
            }
            var renamed = participant
            renamed.displayName = confirmed.displayName
            renamed.speakerLabel = confirmed.displayName
            return renamed
        }
    }

    /// The roster offered as **choices**, e.g. an assignee picker. Confirmed voices collapse into
    /// the one person they belong to, so linking `Speaker 1` and `Speaker 2` to Patrick offers
    /// "Patrick" once rather than three near-identical rows.
    var assignableParticipants: [Participant] {
        var seen: Set<UUID> = []
        var result: [Participant] = []
        for participant in participants {
            guard let confirmed = confirmedParticipant(for: participant.id) else {
                continue
            }
            // A person the user named is offered once a stored segment points at them (the pasted
            // transcript path), or once a diarized voice is explicitly resolved to them (the
            // audio path). Until either happens they would be an assignee who never spoke here.
            let isReferencedByTranscript = transcriptSegments.contains {
                $0.speakerID == participant.id
            }
            if confirmed.id == participant.id,
               participant.speakerLabel == nil,
               !speakerResolutions.contains(where: { $0.resolvedParticipantID == participant.id }),
               !isReferencedByTranscript {
                continue
            }
            if seen.insert(confirmed.id).inserted {
                result.append(confirmed)
            }
        }
        return result
    }
}
