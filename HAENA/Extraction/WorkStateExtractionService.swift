import Foundation

enum WorkStateExtractionServiceError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    case repositoryFailure
}

/// Whether the continuity sidecar reached its own repository. This is intentionally finite: a
/// provider or repository error description must not become a second place that stores transcript
/// text, a title, a person's name, or a path.
enum WorkStateTransitionPersistenceStatus: String, Equatable, Sendable {
    case notConfigured
    case persisted
    case failed
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
    var acceptedProgressSignals: Int = 0
    var acceptedOpenQuestionResolutionLinks: Int = 0
    var acceptedDecisionDerivedActionItemLinks: Int = 0
    var rejectedSignals: [RejectedContinuitySignal] = []
    var transitionPersistenceStatus: WorkStateTransitionPersistenceStatus = .notConfigured
    let metadata: ModelRunMetadata

    var storedCount: Int {
        storedDecisions + storedActionItems + storedOpenQuestions + storedAgendaItems
    }

    var acceptedSignalCount: Int {
        acceptedProgressSignals
            + acceptedOpenQuestionResolutionLinks
            + acceptedDecisionDerivedActionItemLinks
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
    /// Optional for isolated tests and callers that intentionally do not persist continuity. The
    /// app assembly always supplies it.
    let continuity: WorkStateContinuityService?
    let now: @Sendable () -> Date

    init(
        repository: any ProjectRepository,
        extractor: any WorkStateExtractor,
        continuity: WorkStateContinuityService? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.extractor = extractor
        self.continuity = continuity
        self.now = now
    }

    @discardableResult
    func extractAndApply(meetingID: UUID, projectID: UUID) async throws -> WorkStateExtractionReport {
        let initialProject = try await requireProject(projectID)
        guard let meeting = initialProject.meetings.first(where: { $0.id == meetingID }) else {
            throw WorkStateExtractionServiceError.meetingNotFound
        }
        let priorContext = PriorWorkStateContext(
            snapshot: ApprovedWorkStateSnapshot(project: initialProject)
        )

        // Any error here propagates untouched, before a single write.
        let result = try await extractor.extract(
            from: WorkStateExtractionInput(
                meeting: meeting,
                priorWorkStates: priorContext.providerReferences
            )
        )

        // Phase one validates and assigns stable app identity to base work state. Phase two maps
        // sidecars only through accepted provider keys and the local prior-reference allow-list.
        let mapped = WorkStateProposalMapper.map(
            result,
            meeting: meeting,
            now: now(),
            priorReferenceMap: priorContext.referenceMap
        )

        // Re-read: the extraction call may have taken seconds, and the project on disk is the
        // authority. If the meeting was deleted meanwhile, the proposals are dropped rather than
        // resurrecting a record the user removed.
        var project = try await requireProject(projectID)
        guard project.meetings.contains(where: { $0.id == meetingID }) else {
            throw WorkStateExtractionServiceError.meetingNotFound
        }

        let validated = mapped.workState
        let signals = mapped.continuitySignals.revalidated(
            against: ApprovedWorkStateSnapshot(project: project),
            incoming: validated
        )
        let replaced = replaceSupersededProposals(
            for: meetingID,
            with: validated,
            in: &project
        )

        project.updatedAt = now()

        do {
            try await repository.save(project)
        } catch {
            throw WorkStateExtractionServiceError.repositoryFailure
        }

        var persistenceStatus: WorkStateTransitionPersistenceStatus = .notConfigured
        if let continuity {
            do {
                _ = try await continuity.recordTransitions(
                    forProject: projectID,
                    sourceMeetingID: meetingID,
                    incoming: validated,
                    progressSignals: signals.progressSignals,
                    resolutionLinks: signals.openQuestionResolutionLinks,
                    derivedActionItemLinks: signals.decisionDerivedActionItemLinks,
                    decisionChangeLinks: signals.decisionChangeLinks
                )
                persistenceStatus = .persisted
            } catch {
                // The project commit above is authoritative and is never rolled back. The finite
                // report state makes the missing transition write visible without retaining the
                // repository's potentially sensitive free-form error.
                persistenceStatus = .failed
            }
        }

        return WorkStateExtractionReport(
            storedDecisions: validated.decisions.count,
            storedActionItems: validated.actionItems.count,
            storedOpenQuestions: validated.openQuestions.count,
            storedAgendaItems: validated.agendaItems.count,
            replacedProposals: replaced,
            rejected: validated.rejected,
            acceptedProgressSignals: signals.progressSignals.count,
            acceptedOpenQuestionResolutionLinks: signals.openQuestionResolutionLinks.count,
            acceptedDecisionDerivedActionItemLinks: signals.decisionDerivedActionItemLinks.count,
            rejectedSignals: signals.rejected,
            transitionPersistenceStatus: persistenceStatus,
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
    private func replaceSupersededProposals(
        for meetingID: UUID,
        with incoming: ValidatedWorkState,
        in project: inout Project
    ) -> Int {
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

        let priorDecisions = Dictionary(
            uniqueKeysWithValues: project.decisions.filter(supersededDecision).map { ($0.id, $0) }
        )
        let priorActionItems = Dictionary(
            uniqueKeysWithValues: project.actionItems.filter(supersededActionItem).map { ($0.id, $0) }
        )
        let priorQuestions = Dictionary(
            uniqueKeysWithValues: project.openQuestions.filter(supersededQuestion).map { ($0.id, $0) }
        )
        let priorAgendaItems = Dictionary(
            uniqueKeysWithValues: project.nextAgenda.filter(supersededAgendaItem).map { ($0.id, $0) }
        )

        removed += priorDecisions.count
        project.decisions.removeAll(where: supersededDecision)
        removed += priorActionItems.count
        project.actionItems.removeAll(where: supersededActionItem)
        removed += priorQuestions.count
        project.openQuestions.removeAll(where: supersededQuestion)
        removed += priorAgendaItems.count
        project.nextAgenda.removeAll(where: supersededAgendaItem)

        let preservedDecisionIDs = Set(project.decisions.map(\.id))
        project.decisions.append(contentsOf: incoming.decisions.compactMap { proposed in
            guard !preservedDecisionIDs.contains(proposed.id) else { return nil }
            guard let previous = priorDecisions[proposed.id] else { return proposed }
            return Decision(
                id: proposed.id,
                projectID: proposed.projectID,
                meetingID: proposed.meetingID,
                statement: proposed.statement,
                rationale: proposed.rationale,
                status: proposed.status,
                evidence: proposed.evidence,
                confidence: proposed.confidence,
                createdAt: previous.createdAt,
                updatedAt: proposed.updatedAt
            )
        })

        let preservedActionIDs = Set(project.actionItems.map(\.id))
        project.actionItems.append(contentsOf: incoming.actionItems.compactMap { proposed in
            guard !preservedActionIDs.contains(proposed.id) else { return nil }
            guard let previous = priorActionItems[proposed.id] else { return proposed }
            return ActionItem(
                id: proposed.id,
                projectID: proposed.projectID,
                meetingID: proposed.meetingID,
                title: proposed.title,
                details: proposed.details,
                assigneeID: proposed.assigneeID,
                dueDate: proposed.dueDate,
                status: proposed.status,
                evidence: proposed.evidence,
                confidence: proposed.confidence,
                proposedAssigneeAttribution: proposed.proposedAssigneeAttribution,
                createdAt: previous.createdAt,
                updatedAt: proposed.updatedAt
            )
        })

        let preservedQuestionIDs = Set(project.openQuestions.map(\.id))
        project.openQuestions.append(contentsOf: incoming.openQuestions.compactMap { proposed in
            guard !preservedQuestionIDs.contains(proposed.id) else { return nil }
            guard let previous = priorQuestions[proposed.id] else { return proposed }
            return OpenQuestion(
                id: proposed.id,
                projectID: proposed.projectID,
                meetingID: proposed.meetingID,
                question: proposed.question,
                status: proposed.status,
                evidence: proposed.evidence,
                confidence: proposed.confidence,
                createdAt: previous.createdAt,
                resolvedAt: proposed.resolvedAt,
                reviewedAt: proposed.reviewedAt
            )
        })

        let preservedAgendaIDs = Set(project.nextAgenda.map(\.id))
        project.nextAgenda.append(contentsOf: incoming.agendaItems.compactMap { proposed in
            guard !preservedAgendaIDs.contains(proposed.id) else { return nil }
            guard let previous = priorAgendaItems[proposed.id] else { return proposed }
            return AgendaItem(
                id: proposed.id,
                projectID: proposed.projectID,
                title: proposed.title,
                reason: proposed.reason,
                sourceMeetingID: proposed.sourceMeetingID,
                relatedActionItemID: proposed.relatedActionItemID,
                relatedOpenQuestionID: proposed.relatedOpenQuestionID,
                status: proposed.status,
                createdAt: previous.createdAt,
                evidence: proposed.evidence,
                confidence: proposed.confidence,
                reviewedAt: proposed.reviewedAt
            )
        })

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

}
