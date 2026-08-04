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

    init(
        repository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    // MARK: - Decisions

    /// Confirms that the meeting really did decide this.
    func approveDecision(id: UUID, in projectID: UUID) async throws {
        try await setDecisionStatus(.confirmed, id: id, in: projectID)
    }

    /// Rejects the suggestion. The record is kept rather than deleted, so a wrong suggestion stays
    /// visible as something that was considered and turned down.
    func rejectDecision(id: UUID, in projectID: UUID) async throws {
        try await setDecisionStatus(.rejected, id: id, in: projectID)
    }

    func setDecisionStatus(_ status: DecisionStatus, id: UUID, in projectID: UUID) async throws {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.decisions.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            project.decisions[index].status = status
            project.decisions[index].updatedAt = timestamp
        }
    }

    // MARK: - Action items

    func approveActionItem(id: UUID, in projectID: UUID) async throws {
        try await setActionItemStatus(.confirmed, id: id, in: projectID)
    }

    func excludeActionItem(id: UUID, in projectID: UUID) async throws {
        try await setActionItemStatus(.cancelled, id: id, in: projectID)
    }

    func setActionItemStatus(_ status: ActionItemStatus, id: UUID, in projectID: UUID) async throws {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.actionItems.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            project.actionItems[index].status = status
            project.actionItems[index].updatedAt = timestamp
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
        try await mutate(projectID) { project, timestamp in
            guard let index = project.actionItems.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }

            if let assigneeID {
                let meeting = project.meetings.first { $0.id == project.actionItems[index].meetingID }
                guard let meeting, meeting.participants.contains(where: { $0.id == assigneeID }) else {
                    throw WorkStateReviewError.unknownAssignee
                }
            }

            project.actionItems[index].assigneeID = assigneeID
            project.actionItems[index].dueDate = dueDate
            project.actionItems[index].updatedAt = timestamp
        }
    }

    // MARK: - Open questions

    /// Keeps the question open, but marks it as one a person has seen. `status` does not change —
    /// `.open` is already correct — so `reviewedAt` is what separates it from a fresh proposal.
    func approveOpenQuestion(id: UUID, in projectID: UUID) async throws {
        try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.reviewedAt = timestamp
        }
    }

    func dismissOpenQuestion(id: UUID, in projectID: UUID) async throws {
        try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.status = .dismissed
            question.reviewedAt = timestamp
        }
    }

    func resolveOpenQuestion(id: UUID, in projectID: UUID) async throws {
        try await updateOpenQuestion(id: id, in: projectID) { question, timestamp in
            question.status = .resolved
            question.resolvedAt = timestamp
            question.reviewedAt = timestamp
        }
    }

    private func updateOpenQuestion(
        id: UUID,
        in projectID: UUID,
        _ body: @escaping (inout OpenQuestion, Date) -> Void
    ) async throws {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.openQuestions.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            body(&project.openQuestions[index], timestamp)
        }
    }

    // MARK: - Agenda items

    func approveAgendaItem(id: UUID, in projectID: UUID) async throws {
        try await updateAgendaItem(id: id, in: projectID) { item, timestamp in
            item.reviewedAt = timestamp
        }
    }

    func dismissAgendaItem(id: UUID, in projectID: UUID) async throws {
        try await updateAgendaItem(id: id, in: projectID) { item, timestamp in
            item.status = .dismissed
            item.reviewedAt = timestamp
        }
    }

    private func updateAgendaItem(
        id: UUID,
        in projectID: UUID,
        _ body: @escaping (inout AgendaItem, Date) -> Void
    ) async throws {
        try await mutate(projectID) { project, timestamp in
            guard let index = project.nextAgenda.firstIndex(where: { $0.id == id }) else {
                throw WorkStateReviewError.itemNotFound
            }
            body(&project.nextAgenda[index], timestamp)
        }
    }

    // MARK: - Shared write path

    /// Read, mutate, save — with the project's own `updatedAt` advanced once, in one place. A
    /// mutation that throws leaves the stored project untouched, because the save never runs.
    private func mutate(
        _ projectID: UUID,
        _ body: (inout Project, Date) throws -> Void
    ) async throws {
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
        try body(&project, timestamp)
        project.updatedAt = timestamp

        do {
            try await repository.save(project)
        } catch {
            throw WorkStateReviewError.repositoryFailure
        }
    }
}
