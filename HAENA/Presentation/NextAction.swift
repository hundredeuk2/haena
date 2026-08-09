import Foundation

/// The one thing the home screen asks the user to do right now.
///
/// A presentation value, not a domain one: nothing here is stored, no JSON field backs it, and no
/// model is called to produce it. It is a view onto work the user already has, carrying only what
/// the card needs to render and where pressing it should lead.
///
/// Two cases and nothing else, deliberately. An optional `NextAction` is what makes "the home shows
/// exactly one highlighted card, or none" a fact about the type rather than a rule a view has to
/// remember — there is no list here to accidentally render more of.
enum NextAction: Equatable, Sendable {
    /// A project with AI proposals nobody has judged yet. The count, never the proposals: an
    /// unreviewed proposal is a machine's guess, and putting one on the home screen would present
    /// it as settled — the same reason 확인 필요 shows counts.
    case review(Review)
    /// A task the user has confirmed is theirs.
    case work(Work)

    struct Review: Equatable, Sendable {
        let projectID: UUID
        let projectName: String
        /// How many proposals are waiting in *this* project, not across all of them.
        let pendingCount: Int
    }

    struct Work: Equatable, Sendable {
        let actionItemID: UUID
        let title: String
        let projectID: UUID
        let projectName: String
        /// Nil when the stored assignee id matches no participant in that meeting's roster. Never a
        /// placeholder that could be mistaken for a person's name — the card supplies its own
        /// wording, exactly as the 내 업무 rows do.
        let assigneeName: String?
        /// Ready to display, including the "마감일 없음" case, so the card never has to decide what
        /// a missing deadline looks like. Rendered by the policy because a date's text depends on a
        /// calendar, and that is what the policy was handed.
        let dueDateLabel: String
        let isOverdue: Bool
    }

    /// The project this recommendation is about — which is also the project pressing it opens.
    var projectID: UUID {
        switch self {
        case .review(let review): return review.projectID
        case .work(let work): return work.projectID
        }
    }
}

/// Chooses that one thing, from stored projects and the local profile alone.
///
/// Every include/exclude rule here is borrowed rather than invented: `WorkStateInbox` and
/// `PendingAIProposalPolicy` decide what counts as an unreviewed proposal, `WorkStateInbox` decides
/// what counts as work in progress, and `MyWorkPolicy` decides what counts as the user's own. This
/// type owns exactly one new rule — the priority between them — because that is the only question
/// the rest of the app has never had to answer.
///
/// **Review beats everything.** An unreviewed proposal is the app asking the user a question it
/// cannot answer itself, and an overdue task is at worst late; leaving proposals unjudged is what
/// makes every other number on the screen untrustworthy, so they go first.
///
/// **Nothing is ever substituted for the user's own work.** With no profile, or a profile linked to
/// no participant, there is no basis for calling anything "mine" — so the recommendation is either
/// a review or nothing at all. Showing somebody else's task under 지금 할 일 would be the exact
/// mistake `MyWorkPolicy` exists to prevent.
///
/// `referenceDate` and `calendar` are injected rather than read from the machine, so what counts as
/// overdue and how a deadline reads are decided by the caller — which is what lets a test pin both
/// instead of depending on when and where it runs.
struct NextActionPolicy: Sendable {
    let referenceDate: Date
    let calendar: Calendar

    init(referenceDate: Date = Date(), calendar: Calendar = .current) {
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    func next(projects: [Project], profile: LocalUserProfile?) -> NextAction? {
        if let review = longestWaitingReview(in: projects) {
            return .review(review)
        }
        if let work = mostUrgentOwnWork(in: projects, profile: profile) {
            return .work(work)
        }
        return nil
    }

    // MARK: - Unreviewed proposals

    /// The project whose oldest unjudged proposal has been waiting longest.
    ///
    /// Oldest proposal rather than largest pile: a backlog of twelve fresh suggestions is less
    /// overdue an answer than one that has sat there since last month, and a count would make the
    /// noisiest project permanently the recommendation.
    private func longestWaitingReview(in projects: [Project]) -> NextAction.Review? {
        let candidates: [(review: NextAction.Review, waitingSince: Date)] = projects.compactMap { project in
            let pending = WorkStateInbox.pendingProposals(in: project)
            guard let oldest = pending.map(\.createdAt).min() else {
                return nil
            }
            let review = NextAction.Review(
                projectID: project.id,
                projectName: project.name,
                pendingCount: pending.count
            )
            return (review, oldest)
        }

        // A total order, so which project wins never depends on the order they were handed in.
        return candidates.min { lhs, rhs in
            if lhs.waitingSince != rhs.waitingSince {
                return lhs.waitingSince < rhs.waitingSince
            }
            return lhs.review.projectID.uuidString < rhs.review.projectID.uuidString
        }?.review
    }

    // MARK: - The user's own work

    private func mostUrgentOwnWork(in projects: [Project], profile: LocalUserProfile?) -> NextAction.Work? {
        guard MyWorkPolicy.isPersonalised(profile) else {
            return nil
        }

        // `activeActionItems` is what keeps proposed, completed and cancelled work out; `mine`
        // filters one already-built list rather than gathering per linked identity, so a task the
        // user is assigned under two names still appears once.
        let everyonesWork = projects.flatMap { project in
            WorkStateInbox.activeActionItems(in: project).map { HomeActionItem($0, in: project) }
        }
        guard let chosen = MyWorkPolicy.mine(everyonesWork, profile: profile).min(by: Self.isMoreUrgent) else {
            return nil
        }

        return NextAction.Work(
            actionItemID: chosen.actionItem.id,
            title: chosen.actionItem.title,
            projectID: chosen.projectID,
            projectName: chosen.projectName,
            assigneeName: chosen.assigneeName,
            dueDateLabel: dueDateLabel(chosen.actionItem.dueDate),
            isOverdue: isOverdue(chosen.actionItem)
        )
    }

    /// Earliest deadline first, undated work last, ties broken on project then task id.
    ///
    /// One comparison covers both "overdue beats upcoming" and "soonest upcoming first": a breached
    /// deadline is by definition earlier than an unbreached one, so sorting by the date alone puts
    /// the longest-overdue task at the front without overdue-ness being a separate rule that could
    /// disagree with the dates it was derived from. Undated work sorts last rather than being
    /// dropped — no deadline is unknown, not urgent, and not finished either.
    ///
    /// Ties include the project because two projects can hold tasks with the same deadline and the
    /// same generated id shape; without it the choice would come down to which project happened to
    /// be merged first.
    static func isMoreUrgent(_ lhs: HomeActionItem, _ rhs: HomeActionItem) -> Bool {
        switch (lhs.actionItem.dueDate, rhs.actionItem.dueDate) {
        case (let left?, let right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            if lhs.projectID != rhs.projectID {
                return lhs.projectID.uuidString < rhs.projectID.uuidString
            }
            return lhs.actionItem.id.uuidString < rhs.actionItem.id.uuidString
        }
    }

    /// The same rule `HomeSummary` and `ProjectStatusSummary` already apply, so the card's 지남 and
    /// the red deadline in the 내 업무 row below it can never disagree about the same task. Work
    /// with no due date is never overdue — a missing deadline is unknown, not breached.
    func isOverdue(_ actionItem: ActionItem) -> Bool {
        guard let dueDate = actionItem.dueDate else {
            return false
        }
        return dueDate < referenceDate
    }

    /// "마감일 없음" rather than an omitted field: the card has a fixed shape, and a missing line
    /// would read as a deadline the screen failed to load.
    private func dueDateLabel(_ dueDate: Date?) -> String {
        let formatter = MeetingDateFormatter(
            locale: calendar.locale ?? .current,
            timeZone: calendar.timeZone
        )
        return WorkStateDisplay.dueDateLabel(dueDate, formatter: formatter) ?? "마감일 없음"
    }
}
