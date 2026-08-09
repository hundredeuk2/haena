import Foundation

/// One item on the home screen, together with the project it came from.
///
/// The home merges work from every project into one list, so each row has to say where it came
/// from: without that, two identically worded questions from two projects are indistinguishable,
/// and there is nowhere to navigate to.
struct HomeEntry<Value: Identifiable & Equatable & Sendable>: Identifiable, Equatable, Sendable
where Value.ID == UUID {
    let value: Value
    let projectID: UUID
    let projectName: String

    var id: UUID { value.id }
}

/// A task on the home screen.
///
/// Has its own type rather than reusing `HomeEntry` because a cross-project task list has to answer
/// one more question than the others — who it belongs to — and resolving that means reaching into
/// the meeting that produced it. Doing that once here keeps it out of the view.
struct HomeActionItem: Identifiable, Equatable, Sendable {
    let actionItem: ActionItem
    let projectID: UUID
    let projectName: String
    /// Nil when nobody was assigned, or when the stored id matches no participant in that
    /// meeting's roster. Never a placeholder that could be mistaken for a person's name — the
    /// screen supplies its own wording for unassigned work.
    let assigneeName: String?

    var id: UUID { actionItem.id }
}

/// How many proposals are waiting in one project.
///
/// The 확인 필요 area is counts rather than items on purpose, exactly as on the project status
/// screen: an unreviewed proposal is a machine's guess, and listing one beside approved work would
/// present it as settled. Per project rather than one number, so the row can lead somewhere.
struct HomePendingProposalCount: Identifiable, Equatable, Sendable {
    let projectID: UUID
    let projectName: String
    let count: Int

    var id: UUID { projectID }
}

/// A read-only answer to "what needs attention across everything I have", derived entirely from
/// stored `Project` values: nothing here is persisted, no JSON field backs it, and no model is
/// called to produce it.
///
/// Every include/exclude rule is `WorkStateInbox`'s — the same predicates the review screen,
/// the project status screen, and meeting re-extraction already agree on — so the home cannot
/// claim something is settled that the review screen still calls a proposal. What is genuinely
/// this type's own is the merging, the cross-project ordering, and the truncation.
///
/// **This screen is not personalised.** There is no signed-in user and no profile, so it shows
/// every assignee's work and names them. It deliberately does not say "my tasks"; claiming a
/// filter it does not apply would be worse than showing everything.
struct HomeSummary: Equatable, Sendable {
    /// Every proposal awaiting a verdict, across all projects.
    let pendingProposalCount: Int
    /// Where those proposals are. `totalCount` here counts *projects*, not proposals — the
    /// proposal total is `pendingProposalCount`.
    let pendingProposalsByProject: ProjectStatusSection<HomePendingProposalCount>

    let activeActionItems: ProjectStatusSection<HomeActionItem>
    let unresolvedQuestions: ProjectStatusSection<HomeEntry<OpenQuestion>>
    let upcomingAgendaItems: ProjectStatusSection<HomeEntry<AgendaItem>>

    let projectCount: Int

    /// The moment this summary was taken, which is what "overdue" is measured against. Held on the
    /// value rather than read from `Date()` per call, so one rendered home stays internally
    /// consistent and tests can pin it instead of depending on when they run.
    let referenceDate: Date

    /// How many items each area shows before falling back to a count. Five rather than the project
    /// screen's three: this is the whole app in one place, so each area can afford a little more.
    static let representativeLimit = 5

    init(
        projects: [Project],
        referenceDate: Date = Date(),
        limit: Int = HomeSummary.representativeLimit
    ) {
        self.referenceDate = referenceDate
        projectCount = projects.count

        // Merged in a fixed project order, so the input to every sort below is itself stable.
        let ordered = projects.sorted(by: ProjectBrowserQueryService.isOrderedBefore)

        var pendingByProject: [HomePendingProposalCount] = []
        var work: [HomeActionItem] = []
        var questions: [HomeEntry<OpenQuestion>] = []
        var agenda: [HomeEntry<AgendaItem>] = []

        for project in ordered {
            let pending = WorkStateInbox.pendingProposals(in: project).count
            if pending > 0 {
                pendingByProject.append(
                    HomePendingProposalCount(
                        projectID: project.id,
                        projectName: project.name,
                        count: pending
                    )
                )
            }

            work += WorkStateInbox.activeActionItems(in: project).map { item in
                HomeActionItem(
                    actionItem: item,
                    projectID: project.id,
                    projectName: project.name,
                    assigneeName: Self.assigneeName(for: item, in: project)
                )
            }

            questions += WorkStateInbox.reviewedOpenQuestions(in: project).map { question in
                HomeEntry(value: question, projectID: project.id, projectName: project.name)
            }

            agenda += WorkStateInbox.reviewedAgendaItems(in: project).map { item in
                HomeEntry(value: item, projectID: project.id, projectName: project.name)
            }
        }

        pendingProposalCount = pendingByProject.reduce(0) { $0 + $1.count }
        pendingProposalsByProject = ProjectStatusSection(
            all: pendingByProject.sorted(by: Self.isOrderedByPendingCount),
            limit: limit
        )

        // "What should I do next" is a question about deadlines, so work is ordered by due date
        // rather than by when it was last touched — the same re-ordering, and the same comparator,
        // the project status screen already applies.
        activeActionItems = ProjectStatusSection(
            all: work.sorted { ProjectStatusSummary.isOrderedByDueDate($0.actionItem, $1.actionItem) },
            limit: limit
        )

        // Merging two already-sorted lists does not produce a sorted list, so both are re-sorted
        // with the very comparator `WorkStateInbox` used per project.
        unresolvedQuestions = ProjectStatusSection(
            all: questions.sorted { WorkStateInbox.isOrderedBefore($0.value, $1.value) },
            limit: limit
        )
        upcomingAgendaItems = ProjectStatusSection(
            all: agenda.sorted { WorkStateInbox.isOrderedBefore($0.value, $1.value) },
            limit: limit
        )
    }

    /// Every qualifying item rather than the first few, for callers that must not silently drop
    /// state — currently only tests, which need the totals to be checkable item by item.
    static func complete(projects: [Project], referenceDate: Date = Date()) -> HomeSummary {
        HomeSummary(projects: projects, referenceDate: referenceDate, limit: .max)
    }

    /// True when there is nothing at all to act on. Distinct from having no projects: a user can
    /// have projects whose work is all finished, and that is a real, reportable state.
    var hasNothingToShow: Bool {
        pendingProposalCount == 0
            && activeActionItems.isEmpty
            && unresolvedQuestions.isEmpty
            && upcomingAgendaItems.isEmpty
    }

    /// True when this task's deadline has already passed. Work with no due date is never overdue —
    /// a missing deadline is unknown, not breached.
    func isOverdue(_ actionItem: ActionItem) -> Bool {
        guard let dueDate = actionItem.dueDate else {
            return false
        }
        return dueDate < referenceDate
    }

    // MARK: - Ordering

    /// Most waiting first, then by name, then by id — a total order, so the list never reshuffles
    /// between reads of the same data.
    static func isOrderedByPendingCount(
        _ lhs: HomePendingProposalCount,
        _ rhs: HomePendingProposalCount
    ) -> Bool {
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        if lhs.projectName != rhs.projectName {
            return lhs.projectName < rhs.projectName
        }
        return lhs.projectID.uuidString < rhs.projectID.uuidString
    }

    // MARK: - Assignee

    /// Resolved through the meeting's `displayRoster`, so a task assigned to an anonymous speaker
    /// starts showing the real name once that voice has been confirmed — the same lookup the review
    /// and project screens use.
    private static func assigneeName(for item: ActionItem, in project: Project) -> String? {
        let participants = project.meetings.first { $0.id == item.meetingID }?.displayRoster ?? []
        return WorkStateDisplay.assigneeName(item.assigneeID, participants: participants)
    }
}
