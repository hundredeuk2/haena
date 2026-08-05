import Foundation

enum WorkStateExtractionServiceError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    case repositoryFailure
}

/// What one `extractAndApply` run changed, for callers that want to report it without re-reading
/// the project.
struct WorkStateExtractionReport: Equatable, Sendable {
    var storedDecisions: Int = 0
    var storedActionItems: Int = 0
    var storedOpenQuestions: Int = 0
    var storedAgendaItems: Int = 0
    /// How many previously stored, still-unreviewed proposals from this meeting were replaced.
    var replacedProposals: Int = 0
    var rejected: [RejectedProposal] = []
    let metadata: ModelRunMetadata

    var storedCount: Int {
        storedDecisions + storedActionItems + storedOpenQuestions + storedAgendaItems
    }
}

/// Runs an extractor over a stored meeting and persists the verified proposals into its project.
///
/// Ordering is deliberate: the extraction (a slow, failure-prone network call) happens *between*
/// two repository reads and before any write. A failure therefore cannot touch stored data — the
/// transcript the user typed survives every provider outage — and the project is re-read after
/// the call so a concurrent edit made while the model was thinking is not clobbered.
struct WorkStateExtractionService: Sendable {
    let repository: any ProjectRepository
    let extractor: any WorkStateExtractor
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        repository: any ProjectRepository,
        extractor: any WorkStateExtractor,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.extractor = extractor
        self.now = now
        self.makeID = makeID
    }

    @discardableResult
    func extractAndApply(meetingID: UUID, projectID: UUID) async throws -> WorkStateExtractionReport {
        let meeting = try await requireMeeting(meetingID: meetingID, projectID: projectID)

        // Any error here propagates untouched, before a single write.
        let result = try await extractor.extract(from: WorkStateExtractionInput(meeting: meeting))

        // Re-read: the extraction call may have taken seconds, and the project on disk is the
        // authority. If the meeting was deleted meanwhile, the proposals are dropped rather than
        // resurrecting a record the user removed.
        var project = try await requireProject(projectID)
        guard project.meetings.contains(where: { $0.id == meetingID }) else {
            throw WorkStateExtractionServiceError.meetingNotFound
        }

        let validated = WorkStateProposalMapper.map(result, meeting: meeting, now: now(), makeID: makeID)
        let replaced = removeSupersededProposals(for: meetingID, from: &project)

        project.decisions.append(contentsOf: validated.decisions)
        project.actionItems.append(contentsOf: validated.actionItems)
        project.openQuestions.append(contentsOf: validated.openQuestions)
        project.nextAgenda.append(contentsOf: validated.agendaItems)
        project.updatedAt = now()

        do {
            try await repository.save(project)
        } catch {
            throw WorkStateExtractionServiceError.repositoryFailure
        }

        return WorkStateExtractionReport(
            storedDecisions: validated.decisions.count,
            storedActionItems: validated.actionItems.count,
            storedOpenQuestions: validated.openQuestions.count,
            storedAgendaItems: validated.agendaItems.count,
            replacedProposals: replaced,
            rejected: validated.rejected,
            metadata: result.metadata
        )
    }

    // MARK: - Re-run policy

    /// Re-extracting a meeting **replaces** its previous suggestions instead of appending to them,
    /// so running twice cannot silently double every item.
    ///
    /// Only unreviewed, AI-derived records are removed: an item is superseded when it comes from
    /// this meeting *and* `PendingAIProposalPolicy.isPending` says it is still an unreviewed
    /// proposal — the same test the review inbox uses to decide what to show. Anything a user
    /// confirmed, approved, resolved, dismissed, or hand-entered fails that test and is kept.
    private func removeSupersededProposals(for meetingID: UUID, from project: inout Project) -> Int {
        var removed = 0

        let supersededDecision: (Decision) -> Bool = {
            $0.meetingID == meetingID && PendingAIProposalPolicy.isPending($0)
        }
        let supersededActionItem: (ActionItem) -> Bool = {
            $0.meetingID == meetingID && PendingAIProposalPolicy.isPending($0)
        }
        let supersededQuestion: (OpenQuestion) -> Bool = {
            $0.meetingID == meetingID && PendingAIProposalPolicy.isPending($0)
        }
        let supersededAgendaItem: (AgendaItem) -> Bool = {
            $0.sourceMeetingID == meetingID && PendingAIProposalPolicy.isPending($0)
        }

        removed += project.decisions.countMatching(supersededDecision)
        project.decisions.removeAll(where: supersededDecision)

        removed += project.actionItems.countMatching(supersededActionItem)
        project.actionItems.removeAll(where: supersededActionItem)

        removed += project.openQuestions.countMatching(supersededQuestion)
        project.openQuestions.removeAll(where: supersededQuestion)

        removed += project.nextAgenda.countMatching(supersededAgendaItem)
        project.nextAgenda.removeAll(where: supersededAgendaItem)

        return removed
    }

    // MARK: - Loading

    private func requireProject(_ projectID: UUID) async throws -> Project {
        let project: Project?
        do {
            project = try await repository.project(id: projectID)
        } catch {
            throw WorkStateExtractionServiceError.repositoryFailure
        }
        guard let project else {
            throw WorkStateExtractionServiceError.projectNotFound
        }
        return project
    }

    private func requireMeeting(meetingID: UUID, projectID: UUID) async throws -> Meeting {
        let project = try await requireProject(projectID)
        guard let meeting = project.meetings.first(where: { $0.id == meetingID }) else {
            throw WorkStateExtractionServiceError.meetingNotFound
        }
        return meeting
    }
}

private extension Array {
    /// Deliberately not named `count(where:)` to avoid shadowing the stdlib method of that name.
    func countMatching(_ isIncluded: (Element) -> Bool) -> Int {
        reduce(into: 0) { total, element in
            if isIncluded(element) {
                total += 1
            }
        }
    }
}
