import Foundation

/// The one definition of "this is mine".
///
/// Every screen asks this type rather than comparing participant ids itself, for the same reason
/// `PendingAIProposalPolicy` exists: the moment two places answer the question, they drift, and the
/// way this one drifts is by showing somebody else's work under the user's own name.
///
/// The rule is deliberately narrow. Work is mine only when the user has confirmed the assignee is
/// them. Unassigned work is not mine — nobody has taken it — and no amount of name similarity makes
/// work mine, because a string comparison has no authority to decide who someone is.
enum MyWorkPolicy {
    /// Whether "my work" means anything yet. False with no profile, and false with a profile that
    /// has not been linked to any participant — in both cases the honest answer is to keep showing
    /// everyone's work rather than to guess.
    static func isPersonalised(_ profile: LocalUserProfile?) -> Bool {
        profile?.isIdentified == true
    }

    /// Whether this task belongs to the user.
    ///
    /// Takes the whole item rather than just an assignee id so callers cannot accidentally ask
    /// about something else, and returns false for every uncertain case.
    static func isMine(_ actionItem: ActionItem, profile: LocalUserProfile?) -> Bool {
        guard let profile, profile.isIdentified else {
            return false
        }
        guard let assigneeID = actionItem.assigneeID else {
            // Nobody owns it. Claiming it would be inventing an assignment the meeting never made.
            return false
        }
        return profile.isLinked(assigneeID)
    }

    /// Filters a list of already-selected work down to the user's own.
    ///
    /// Filtering rather than gathering per linked participant is what makes duplicates impossible:
    /// each task is considered exactly once, no matter how many of the user's identities are
    /// involved in it. It also preserves whatever order it was handed, so the caller's sorting —
    /// due date, in practice — survives untouched.
    static func mine(_ items: [HomeActionItem], profile: LocalUserProfile?) -> [HomeActionItem] {
        items.filter { isMine($0.actionItem, profile: profile) }
    }
}
