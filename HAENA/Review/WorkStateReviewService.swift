import Foundation

enum WorkStateReviewError: Error, Equatable, Sendable {
    case projectNotFound
    case itemNotFound
    /// An assignee was named who is not a participant of the meeting the item came from.
    case unknownAssignee
    case repositoryFailure
}

/// Applies a user's verdict to AI-proposed work state: approve it, exclude it, or correct its
/// details.
///
/// This is the half of the trust loop that extraction cannot do for itself. Nothing a model
/// proposes becomes confirmed without passing through here, and every method is a deliberate,
/// single-item act — there is no "approve all", because the point of the step is that a person
/// looked at each one.
struct WorkStateReviewService: Sendable {
    let repository: any ProjectRepository
    let now: @Sendable () -> Date
    /// Optional and nil by default, so every existing call site keeps compiling and nothing is
    /// forced to construct one. When absent, this service behaves exactly as it did before.
    ///
    /// Instrumenting here rather than in `WorkStateReviewView`/`MeetingResultsView` is deliberate:
    /// both screens offer the same verdicts through this one type, so counting them here is the
    /// only way the two cannot drift apart.
    let metrics: BetaMetricsService?

    init(
        repository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        metrics: BetaMetricsService? = nil
    ) {
        self.repository = repository
        self.now = now
        self.metrics = metrics
    }

    // MARK: - Decisions

    /// Confirms that the meeting really did decide this.
    func approveDecision(id: UUID, in projectID: UUID) async throws {
        try await applyDecisionVerdict(.confirmed, verdict: .approved, id: id, in: projectID)
    }

    /// Rejects the suggestion. The record is kept rather than deleted, so a wrong suggestion stays
    /// visible as something that was considered and turned down.
    func rejectDecision(id: UUID, in projectID: UUID) async throws {
        try await applyDecisionVerdict(.rejected, verdict: .excluded, id: id, in: projectID)
    }

    /// The unlabelled status setter stays a plain mutation. It is how a *reviewed* record is moved
    /// around later, which is not a verdict on a proposal, so it records nothing.
    func setDecisionStatus(_ status: DecisionStatus, id: UUID, in projectID: UUID) async throws {
        _ = try await applyDecisionStatus(status, id: id, in: projectID)
    }

    private func applyDecisionVerdict(
        _ status: DecisionStatus,
        verdict: BetaMetricVerdict,
        id: UUID,
        in projectID: UUID
    ) async throws {
        let wasPendingProposal = try await applyDecisionStatus(status, id: id, in: projectID)
        await recordVerdict(
            verdict,
            kind: .decision,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    /// Returns whether the record this verdict landed on was an unreviewed AI proposal.
    private func applyDecisionStatus(
        _ status: DecisionStatus,
        id: UUID,
        in projectID: UUID
    ) async throws -> Bool {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.decisions.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            let wasPendingProposal = PendingAIProposalPolicy.isPending(project.decisions[index])
            project.decisions[index].status = status
            project.decisions[index].updatedAt = timestamp
            return wasPendingProposal
        }
    }

    // MARK: - Action items

    func approveActionItem(id: UUID, in projectID: UUID) async throws {
        try await applyActionItemVerdict(.confirmed, verdict: .approved, id: id, in: projectID)
    }

    func excludeActionItem(id: UUID, in projectID: UUID) async throws {
        try await applyActionItemVerdict(.cancelled, verdict: .excluded, id: id, in: projectID)
    }

    /// See `setDecisionStatus`: moving an already-reviewed task through its lifecycle is not a
    /// verdict, so it records nothing.
    func setActionItemStatus(_ status: ActionItemStatus, id: UUID, in projectID: UUID) async throws {
        _ = try await applyActionItemStatus(status, id: id, in: projectID)
    }

    private func applyActionItemVerdict(
        _ status: ActionItemStatus,
        verdict: BetaMetricVerdict,
        id: UUID,
        in projectID: UUID
    ) async throws {
        let wasPendingProposal = try await applyActionItemStatus(status, id: id, in: projectID)
        await recordVerdict(
            verdict,
            kind: .actionItem,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    private func applyActionItemStatus(
        _ status: ActionItemStatus,
        id: UUID,
        in projectID: UUID
    ) async throws -> Bool {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.actionItems.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            let wasPendingProposal = PendingAIProposalPolicy.isPending(project.actionItems[index])
            project.actionItems[index].status = status
            project.actionItems[index].updatedAt = timestamp
            return wasPendingProposal
        }
    }

    /// Corrects the two fields extraction is most often unable to fill: who owns the task and when
    /// it is due. Passing nil for either clears it.
    ///
    /// An assignee is validated against the participants of the meeting the item came from. The
    /// extractor refuses to guess an owner, and this path must not become a way to attach one who
    /// was never in the room.
    func updateActionItem(
        id: UUID,
        in projectID: UUID,
        assigneeID: UUID?,
        dueDate: Date?
    ) async throws {
        let changedFields = try await mutate(projectID) { project, timestamp in
            guard let index = project.actionItems.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }

            if let assigneeID {
                let meeting = project.meetings.first { $0.id == project.actionItems[index].meetingID }
                guard let meeting, meeting.participants.contains(where: { $0.id == assigneeID }) else {
                    throw WorkStateReviewError.unknownAssignee
                }
            }

            // Read before the write, because the point of the measure is which fields the model
            // got wrong — and only for an AI proposal a person has not ruled on yet. Correcting
            // an already-approved task is ordinary editing, not a correction of a proposal.
            let existing = project.actionItems[index]
            var changed: [BetaMetricFieldCategory] = []
            if PendingAIProposalPolicy.isPending(existing) {
                if existing.assigneeID != assigneeID {
                    changed.append(.assignee)
                }
                if existing.dueDate != dueDate {
                    changed.append(.dueDate)
                }
            }

            project.actionItems[index].assigneeID = assigneeID
            project.actionItems[index].dueDate = dueDate
            project.actionItems[index].updatedAt = timestamp
            return changed
        }

        // Only the category is recorded — never who was named or which date was chosen. These are
        // the only two fields today's edit sheet can change, and the measure claims no more.
        guard let metrics else {
            return
        }
        for field in changedFields {
            await metrics.recordProposalModified(
                projectID: projectID,
                proposalID: id,
                kind: .actionItem,
                field: field
            )
        }
    }

    // MARK: - Open questions

    /// Keeps the question open, but marks it as one a person has seen. `status` does not change —
    /// `.open` is already correct — so `reviewedAt` is what separates it from a fresh proposal.
    func approveOpenQuestion(id: UUID, in projectID: UUID) async throws {
        let wasPendingProposal = try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.reviewedAt = timestamp
        }
        await recordVerdict(
            .approved,
            kind: .openQuestion,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    func dismissOpenQuestion(id: UUID, in projectID: UUID) async throws {
        let wasPendingProposal = try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.status = .dismissed
            question.reviewedAt = timestamp
        }
        await recordVerdict(
            .excluded,
            kind: .openQuestion,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    /// Answering a question is a later act on something already reviewed, not a verdict on a
    /// proposal, and no screen offers it as one — so it records nothing.
    func resolveOpenQuestion(id: UUID, in projectID: UUID) async throws {
        _ = try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.status = .resolved
            question.resolvedAt = timestamp
            question.reviewedAt = timestamp
        }
    }

    /// Returns whether the question this landed on was an unreviewed AI proposal.
    @discardableResult
    private func updateOpenQuestion(
        id: UUID,
        in projectID: UUID,
        _ body: @escaping (inout OpenQuestion, Date) -> Void
    ) async throws -> Bool {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.openQuestions.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            let wasPendingProposal = PendingAIProposalPolicy.isPending(project.openQuestions[index])
            body(&project.openQuestions[index], timestamp)
            return wasPendingProposal
        }
    }

    // MARK: - Agenda items

    func approveAgendaItem(id: UUID, in projectID: UUID) async throws {
        let wasPendingProposal = try await updateAgendaItem(id: id, in: projectID) { item, timestamp in
            item.reviewedAt = timestamp
        }
        await recordVerdict(
            .approved,
            kind: .agendaItem,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    func dismissAgendaItem(id: UUID, in projectID: UUID) async throws {
        let wasPendingProposal = try await updateAgendaItem(id: id, in: projectID) { item, timestamp in
            item.status = .dismissed
            item.reviewedAt = timestamp
        }
        await recordVerdict(
            .excluded,
            kind: .agendaItem,
            proposalID: id,
            in: projectID,
            whenPendingProposal: wasPendingProposal
        )
    }

    /// Returns whether the agenda item this landed on was an unreviewed AI proposal.
    @discardableResult
    private func updateAgendaItem(
        id: UUID,
        in projectID: UUID,
        _ body: @escaping (inout AgendaItem, Date) -> Void
    ) async throws -> Bool {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.nextAgenda.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            let wasPendingProposal = PendingAIProposalPolicy.isPending(project.nextAgenda[index])
            body(&project.nextAgenda[index], timestamp)
            return wasPendingProposal
        }
    }

    // MARK: - Measurement

    /// Counts one verdict, and only ever after the write it describes has already succeeded — the
    /// call sites reach this line only on a path `mutate` returned from normally, so a verdict that
    /// failed to persist is never counted as one the user gave.
    ///
    /// `whenPendingProposal` is `PendingAIProposalPolicy`'s answer, read from the stored record
    /// *before* the mutation: a hand-entered item (no evidence) is nobody's proposal, and a record
    /// a person has already ruled on cannot be reviewed a second time.
    ///
    /// Non-throwing by construction. `recordProposalReviewed` swallows its own failures, so there
    /// is no error here to propagate and no way for this line to affect the verdict that preceded
    /// it.
    private func recordVerdict(
        _ verdict: BetaMetricVerdict,
        kind: BetaMetricProposalKind,
        proposalID: UUID,
        in projectID: UUID,
        whenPendingProposal: Bool
    ) async {
        guard whenPendingProposal, let metrics else {
            return
        }
        await metrics.recordProposalReviewed(
            projectID: projectID,
            proposalID: proposalID,
            kind: kind,
            verdict: verdict
        )
    }

    // MARK: - Shared write path

    /// Read, mutate, save — with the project's own `updatedAt` advanced once, in one place. A
    /// mutation that throws leaves the stored project untouched, because the save never runs.
    ///
    /// The mutation's return value is what the caller learned about the record while it held it,
    /// and is delivered only on the path where the save succeeded.
    private func mutate<T>(
        _ projectID: UUID,
        _ body: (inout Project, Date) throws -> T
    ) async throws -> T {
        let loaded: Project?
        do {
            loaded = try await repository.project(id: projectID)
        } catch {
            throw WorkStateReviewError.repositoryFailure
        }
        guard var project = loaded else {
            throw WorkStateReviewError.projectNotFound
        }

        let timestamp = now()
        let result = try body(&project, timestamp)
        project.updatedAt = timestamp

        do {
            try await repository.save(project)
        } catch {
            throw WorkStateReviewError.repositoryFailure
        }

        return result
    }
}
