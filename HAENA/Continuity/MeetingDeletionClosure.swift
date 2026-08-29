import Foundation

/// Everything in the transition sidecar that stops making sense once one meeting and its Work State
/// are gone.
///
/// Deleting a meeting is an explicit user verdict: the meeting, the Work State it produced, and the
/// approved and rejected verdicts about that Work State all go. `meetingID` keeps meaning "the
/// meeting this came from", so nothing is rehomed to the project and no tombstone is left behind.
///
/// Split out as a pure value so the rule can be read and tested without a repository, a file, or a
/// clock — the closure is the part that is easy to get subtly wrong, and it is the part that decides
/// whether an unrelated meeting's verdict survives byte-for-byte.
struct MeetingDeletionClosure: Equatable, Sendable {
    /// `dedupKey`s, because that is what the store keys proposals and reviews by.
    let proposalKeys: Set<String>
    let ambiguousMatchGroupKeys: Set<String>
    let refusalKeys: Set<String>
    let ambiguityGroupIDs: Set<UUID>
    let applyIntentKeys: Set<String>

    var isEmpty: Bool {
        proposalKeys.isEmpty
            && ambiguousMatchGroupKeys.isEmpty
            && refusalKeys.isEmpty
            && ambiguityGroupIDs.isEmpty
            && applyIntentKeys.isEmpty
    }

    /// Resolves the closure by typed UUID reference only.
    ///
    /// Two ways in, and both are exact identity comparisons — never a title, never a heuristic:
    ///
    /// 1. **From the meeting.** Proposals, ambiguity groups and refusals whose `sourceMeetingID` is
    ///    the deleted one. These are the orphans the bug report describes.
    /// 2. **From the Work State.** Proposals, refusals and ambiguity groups belonging to *other*
    ///    meetings that point at an object this deletion removes — through `currentObjectID`,
    ///    `previousStateID`, a proposal's typed `relations`, or a group's `incomingObjectID` and
    ///    `priorCandidateIDs`. Without this, a later meeting keeps a record whose subject no longer
    ///    exists, which is the same orphan wearing a different hat.
    ///
    /// One pass is enough, and that is a property of the rule rather than a shortcut: reaching a
    /// transition through a removed object does not remove any further objects, so there is nothing
    /// for a second pass to discover.
    ///
    /// Reviews and apply intents follow whatever they were about. A verdict on a proposal that is
    /// going cannot be kept — there would be nothing left for it to be a verdict on.
    static func resolve(
        meetingID: UUID,
        projectID: UUID,
        removedWorkStateIDs: Set<UUID>,
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        refusals: [WorkStateTransitionRefusalRecord],
        applyIntents: [WorkStateTransitionApplyIntent]
    ) -> MeetingDeletionClosure {
        // Scoped to the project throughout. A UUID collision across projects is not expected, but
        // "not expected" is not a reason to let a deletion reach into another project's sidecar.
        let scopedProposals = proposals.filter { $0.projectID == projectID }

        func touchesRemovedObject(_ proposal: WorkStateTransitionProposal) -> Bool {
            if let current = proposal.currentObjectID, removedWorkStateIDs.contains(current) {
                return true
            }
            if let previous = proposal.previousStateID, removedWorkStateIDs.contains(previous) {
                return true
            }
            return proposal.relations.contains { removedWorkStateIDs.contains($0.relatedObjectID) }
        }

        /// Same question for an ambiguity group. A group is a question — "is this incoming object
        /// one of these prior ones, or new?" — so it needs every object it names to still exist.
        /// Lose the incoming one and there is nothing to ask about; lose a candidate and the answer
        /// set silently changes under a user who has not answered yet.
        ///
        /// `incomingObjectID` is non-optional here, unlike the two references on a proposal: a
        /// group without something incoming would not be a question at all.
        func touchesRemovedObject(_ group: WorkStateAmbiguousMatchGroup) -> Bool {
            if removedWorkStateIDs.contains(group.incomingObjectID) {
                return true
            }
            return group.priorCandidateIDs.contains { removedWorkStateIDs.contains($0) }
        }

        /// Same question for a refusal, which carries the same two typed object references but no
        /// `relations` — a refusal records that a transition was *not* made, so there is no accepted
        /// link hanging off it. Two paths here is the whole shape, not an abbreviation of three.
        func touchesRemovedObject(_ refusal: WorkStateTransitionRefusalRecord) -> Bool {
            if let current = refusal.currentObjectID, removedWorkStateIDs.contains(current) {
                return true
            }
            if let previous = refusal.previousStateID, removedWorkStateIDs.contains(previous) {
                return true
            }
            return false
        }

        let doomedProposals = scopedProposals.filter {
            $0.sourceMeetingID == meetingID || touchesRemovedObject($0)
        }
        let proposalKeys = Set(doomedProposals.map(\.dedupKey))
        let proposalIDs = Set(doomedProposals.map(\.id))

        // `projectID` first and on its own, for the same reason as the refusals below: the object
        // test compares bare UUIDs, and scoping after it would let a collision reach into another
        // project's sidecar before the guard ever ran.
        let doomedGroups = ambiguousMatchGroups.filter { group in
            guard group.projectID == projectID else { return false }
            return group.sourceMeetingID == meetingID || touchesRemovedObject(group)
        }
        let groupKeys = Set(doomedGroups.map(\.dedupKey))
        let groupIDs = Set(doomedGroups.map(\.id))

        // A refusal explains why one object could not be carried forward, so it is only meaningful
        // while that object exists. One left pointing at a deleted object is not an audit record —
        // it is an explanation of a decision about something nobody can look at any more.
        //
        // `projectID` is checked first and separately: the object-reference test below compares
        // bare UUIDs, and scoping afterwards would let a collision reach into another project's
        // sidecar before the guard ever ran.
        let doomedRefusals = refusals.filter { refusal in
            guard refusal.projectID == projectID else { return false }
            return refusal.sourceMeetingID == meetingID || touchesRemovedObject(refusal)
        }

        // An intent is identified by the operation it would finish. It goes if that operation's
        // subject is going — either because the intent names the proposal or group directly, or
        // because one of the terminal verdicts it carries is about a doomed proposal. Leaving one
        // behind would let recovery try to apply a verdict to something that no longer exists.
        //
        // `groupIDs` is derived from `doomedGroups` above, so widening how a group is condemned
        // widens this with it. That is the reason the group test belongs there and not here.
        let doomedIntents = applyIntents.filter { intent in
            guard intent.projectID == projectID else { return false }
            if intent.terminalReviews.contains(where: { proposalIDs.contains($0.proposalID) }) {
                return true
            }
            switch intent.operationKind {
            case .proposal:
                return proposalIDs.contains(intent.operationID)
            case .ambiguity:
                return groupIDs.contains(intent.operationID)
            }
        }

        return MeetingDeletionClosure(
            proposalKeys: proposalKeys,
            ambiguousMatchGroupKeys: groupKeys,
            refusalKeys: Set(doomedRefusals.map(\.dedupKey)),
            ambiguityGroupIDs: groupIDs,
            applyIntentKeys: Set(doomedIntents.map(\.storageKey))
        )
    }
}

/// Everything in the transition sidecar that belongs to one project, for when the whole project
/// goes.
///
/// A separate type from `MeetingDeletionClosure` on purpose. The two answer different questions and
/// only look alike: a meeting deletion has to chase object references across meetings to find what
/// stopped making sense, while a project deletion is a flat scope test — every row that names this
/// project goes, and no row that does not can be affected by it. Expressing the second as a special
/// case of the first would mean inventing a meeting to stand for the project, and that fiction
/// misses exactly the rows this exists to catch: a project with no meetings left but sidecar rows
/// still in it, and a sidecar that drifted out of step with its aggregate through some earlier
/// deletion.
struct ProjectDeletionClosure: Equatable, Sendable {
    /// `dedupKey`s, because that is what the store keys these by.
    let proposalKeys: Set<String>
    let ambiguousMatchGroupKeys: Set<String>
    let refusalKeys: Set<String>
    let ambiguityGroupIDs: Set<UUID>
    let applyIntentKeys: Set<String>
    let meetingDeletionIntentKeys: Set<String>

    var isEmpty: Bool {
        proposalKeys.isEmpty
            && ambiguousMatchGroupKeys.isEmpty
            && refusalKeys.isEmpty
            && ambiguityGroupIDs.isEmpty
            && applyIntentKeys.isEmpty
            && meetingDeletionIntentKeys.isEmpty
    }

    /// Every row is selected by comparing its own `projectID` to this one. Nothing is matched by
    /// name, by key shape, or by a UUID that merely appears in both projects — an object id shared
    /// across projects selects neither project's rows, because the id is never what is tested.
    ///
    /// `ambiguityReviews` are reached two ways, and both are exact. A review is condemned when its
    /// group is, and also when its own `projectID` matches — the second catches a review whose group
    /// was already removed by some earlier deletion, which the first alone would leave behind
    /// forever.
    ///
    /// Proposal reviews have no such second path. `reviews` is keyed by the proposal's `dedupKey`
    /// and its value is a bare enum, so the only typed route to a project is the proposal that owns
    /// the key. No code path today writes a review without a proposal or removes a proposal without
    /// its review, so this is complete for stores this app produced; a review left behind by some
    /// other means would not be reachable here.
    static func resolve(
        projectID: UUID,
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        ambiguityReviews: [WorkStateAmbiguityReviewState],
        refusals: [WorkStateTransitionRefusalRecord],
        applyIntents: [WorkStateTransitionApplyIntent],
        meetingDeletionIntents: [MeetingDeletionIntent]
    ) -> ProjectDeletionClosure {
        let doomedGroups = ambiguousMatchGroups.filter { $0.projectID == projectID }
        let groupIDsFromGroups = Set(doomedGroups.map(\.id))
        let groupIDsFromReviews = Set(
            ambiguityReviews.filter { $0.projectID == projectID }.map(\.groupID)
        )

        return ProjectDeletionClosure(
            proposalKeys: Set(
                proposals.filter { $0.projectID == projectID }.map(\.dedupKey)
            ),
            ambiguousMatchGroupKeys: Set(doomedGroups.map(\.dedupKey)),
            refusalKeys: Set(
                refusals.filter { $0.projectID == projectID }.map(\.dedupKey)
            ),
            ambiguityGroupIDs: groupIDsFromGroups.union(groupIDsFromReviews),
            applyIntentKeys: Set(
                applyIntents.filter { $0.projectID == projectID }.map(\.storageKey)
            ),
            meetingDeletionIntentKeys: Set(
                meetingDeletionIntents.filter { $0.projectID == projectID }.map(\.storageKey)
            )
        )
    }
}
