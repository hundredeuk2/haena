import Foundation

/// One area of a project's status: the representative items to show, plus how many exist in all.
///
/// The two are separate because the summary screen deliberately shows only the first few of
/// anything — a count that shrank to match would misreport the project.
struct ProjectStatusSection<Item: Equatable & Sendable>: Equatable, Sendable {
    let items: [Item]
    let totalCount: Int

    var isEmpty: Bool { totalCount == 0 }

    /// How many exist beyond the ones being shown, for a "+N" affordance. Never negative.
    var hiddenCount: Int { max(0, totalCount - items.count) }
}

/// A read-only answer to "where does this project stand right now", derived entirely from an
/// existing `Project` value: nothing here is stored, no JSON field backs it, and no model is
/// called to produce it.
///
/// This type exists so the 현재 상태 screen owns no filtering or ordering rules of its own. Every
/// section reuses `WorkStateInbox`, the same predicates the review screen and re-extraction
/// already agree on, so the summary cannot drift from the screen a user navigates to from it.
/// The one rule that is genuinely new here is due-date ordering for work in progress.
struct ProjectStatusSummary: Equatable, Sendable {
    /// How many AI proposals are still waiting on a person.
    ///
    /// Deliberately a count and nothing more: an unreviewed proposal is not part of what the
    /// project has decided, and listing one beside approved work would present a machine's guess
    /// as settled fact. The only thing this screen does with proposals is point at the review
    /// screen where their evidence and confidence can be judged.
    let pendingProposalCount: Int

    let recentDecisions: ProjectStatusSection<Decision>
    let activeActionItems: ProjectStatusSection<ActionItem>
    let unresolvedQuestions: ProjectStatusSection<OpenQuestion>
    let upcomingAgendaItems: ProjectStatusSection<AgendaItem>

    /// The moment this summary was taken, which is what "overdue" is measured against. Held on the
    /// value rather than read from `Date()` at each call so one rendered summary stays internally
    /// consistent, and so tests can pin it instead of depending on when they run.
    let referenceDate: Date

    /// How many items each section shows before falling back to a count. Three keeps every section
    /// visible at once on the smallest supported window, which is the entire point of the screen.
    static let representativeLimit = 3

    init(project: Project, referenceDate: Date = Date(), limit: Int = ProjectStatusSummary.representativeLimit) {
        self.referenceDate = referenceDate

        pendingProposalCount = WorkStateInbox.pendingProposals(in: project).count

        // Already ordered newest-first by `WorkStateInbox`, so "recent" is just the first few.
        recentDecisions = Self.section(WorkStateInbox.confirmedDecisions(in: project), limit: limit)

        // The one place the summary re-orders rather than reuses: the review screen lists work by
        // when it was last touched, but "what should I do next" is a question about deadlines.
        let activeWork = WorkStateInbox.activeActionItems(in: project).sorted(by: Self.isOrderedByDueDate)
        activeActionItems = Self.section(activeWork, limit: limit)

        unresolvedQuestions = Self.section(WorkStateInbox.reviewedOpenQuestions(in: project), limit: limit)
        upcomingAgendaItems = Self.section(WorkStateInbox.reviewedAgendaItems(in: project), limit: limit)
    }

    /// True when this item's deadline has already passed. Work with no due date is never overdue —
    /// a missing deadline is unknown, not breached, and inventing one here would be the same
    /// fabrication the extractor refuses to make.
    func isOverdue(_ actionItem: ActionItem) -> Bool {
        guard let dueDate = actionItem.dueDate else {
            return false
        }
        return dueDate < referenceDate
    }

    /// Soonest deadline first; work with no due date sorts last rather than being dropped or
    /// treated as urgent. Ties break on id so the order is total and never reshuffles between
    /// reads of the same data.
    static func isOrderedByDueDate(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case (let left?, let right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func section<Item: Equatable & Sendable>(
        _ items: [Item],
        limit: Int
    ) -> ProjectStatusSection<Item> {
        ProjectStatusSection(items: Array(items.prefix(max(0, limit))), totalCount: items.count)
    }
}
