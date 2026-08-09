import Foundation

/// One person as they appear in one meeting, offered as something the user can point at and say
/// "that is me".
///
/// The provenance is not decoration. A `Participant` is meeting-scoped, so the same human shows up
/// as a different record in every meeting, and two different people can easily carry the same
/// display name. Without the project and meeting beside it, a list of names is unusable for exactly
/// the choice it exists to support.
struct ParticipantDirectoryEntry: Identifiable, Equatable, Sendable {
    let participantID: UUID
    let displayName: String
    let projectID: UUID
    let projectName: String
    let meetingID: UUID
    let meetingTitle: String
    let isLinkedToMe: Bool

    var id: UUID { participantID }
}

/// Builds the list of participants the user could identify themselves with.
///
/// **It never decides anything.** It does not group by name, rank by similarity, or pre-select
/// anyone — the user picks, and only what the user picked is treated as them. Sorting by name is
/// for finding a row, not for suggesting one.
enum ParticipantDirectory {
    /// Every participant across every stored meeting, in a stable order.
    ///
    /// Names come from each meeting's `displayRoster`, so a voice the user already confirmed as a
    /// real person appears under that person's name rather than as `Speaker 2` — the existing
    /// speaker resolutions are read here and never written to.
    static func entries(in projects: [Project], profile: LocalUserProfile?) -> [ParticipantDirectoryEntry] {
        var entries: [ParticipantDirectoryEntry] = []

        for project in projects.sorted(by: ProjectBrowserQueryService.isOrderedBefore) {
            for meeting in ProjectBrowserQueryService.sortedMeetings(project.meetings) {
                for participant in meeting.displayRoster {
                    entries.append(
                        ParticipantDirectoryEntry(
                            participantID: participant.id,
                            displayName: participant.displayName,
                            projectID: project.id,
                            projectName: project.name,
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            isLinkedToMe: profile?.isLinked(participant.id) ?? false
                        )
                    )
                }
            }
        }

        return entries.sorted(by: isOrderedBefore)
    }

    /// Already-linked people first so the user can see and undo what they have chosen, then by
    /// name, then by project, then by id — a total order, so the list never reshuffles between
    /// reads of the same data.
    static func isOrderedBefore(
        _ lhs: ParticipantDirectoryEntry,
        _ rhs: ParticipantDirectoryEntry
    ) -> Bool {
        if lhs.isLinkedToMe != rhs.isLinkedToMe {
            return lhs.isLinkedToMe
        }
        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }
        if lhs.projectName != rhs.projectName {
            return lhs.projectName < rhs.projectName
        }
        return lhs.participantID.uuidString < rhs.participantID.uuidString
    }

    /// The ids that actually exist in the stored meetings. Used to keep the profile from
    /// accumulating links to participants that were never there.
    static func knownParticipantIDs(in projects: [Project]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for project in projects {
            for meeting in project.meetings {
                for participant in meeting.participants {
                    ids.insert(participant.id)
                }
            }
        }
        return ids
    }
}
