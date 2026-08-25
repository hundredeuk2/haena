import Foundation

enum WorkStateTransitionReviewAction: Equatable, Sendable {
    case approve
    case reject
}

enum WorkStateTransitionReviewRefusalReason: String, Codable, Equatable, Sendable, Error {
    case projectNotFound = "project_not_found"
    case proposalNotFound = "proposal_not_found"
    case ambiguityGroupNotFound = "ambiguity_group_not_found"
    case projectMismatch = "project_mismatch"
    case terminalVerdictConflict = "terminal_verdict_conflict"
    case unsupportedTransition = "unsupported_transition"
    case staleProposal = "stale_proposal"
    case crossProjectObject = "cross_project_object"
    case evidenceNoLongerExists = "evidence_no_longer_exists"
    case invalidAmbiguitySelection = "invalid_ambiguity_selection"
    case projectPersistenceFailed = "project_persistence_failed"
    case reviewPersistenceFailed = "review_persistence_failed"
}

enum WorkStateTransitionReviewResult: Equatable, Sendable {
    case applied
    case alreadyApplied
    case rejected
    case alreadyRejected
    case refused(WorkStateTransitionReviewRefusalReason)
    /// The Project mutation and durable apply marker are saved, but the terminal transition
    /// verdict is not. A later app launch resumes from the persisted intent without replaying it.
    case projectSavedReviewPersistenceFailed
}

enum WorkStateTransitionAmbiguityReviewResult: Equatable, Sendable {
    case applied
    case alreadyApplied
    case refused(WorkStateTransitionReviewRefusalReason)
    case projectSavedReviewPersistenceFailed
}

struct WorkStateTransitionApplyRecoveryOutcome: Equatable, Sendable {
    let operationID: UUID
    let operationKind: WorkStateTransitionApplyOperationKind
    let result: WorkStateTransitionReviewResult
}

/// Finite durability boundaries exposed only through dependency injection.
///
/// Production assembles a no-op observer. A Debug-only process smoke harness can terminate the
/// app at one of these boundaries without adding a crash switch to the persistence repositories.
enum WorkStateTransitionApplyCheckpoint: String, Equatable, Sendable {
    case intentStored = "after_intent"
    case projectAndMarkerStored = "after_project_marker"
    case verdictAndIntentCleanupStored = "after_cleanup"
}

/// Applies a human verdict without letting a transition proposal mutate Project state directly.
///
/// A durable intent is written before Project mutation. Project state and its apply marker are
/// then saved atomically, followed by one atomic sidecar write that records the verdict and removes
/// the intent. The marker makes launch-time recovery idempotent without storing private content.
actor WorkStateTransitionReviewService {
    private let projectRepository: any WorkStateTransitionProjectRepository
    private let transitionRepository: any WorkStateTransitionRepository
    private let now: @Sendable () -> Date
    private let didReachCheckpoint: @Sendable (WorkStateTransitionApplyCheckpoint) -> Void

    init(
        projectRepository: any WorkStateTransitionProjectRepository,
        transitionRepository: any WorkStateTransitionRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        didReachCheckpoint: @escaping @Sendable (WorkStateTransitionApplyCheckpoint) -> Void = { _ in }
    ) {
        self.projectRepository = projectRepository
        self.transitionRepository = transitionRepository
        self.now = now
        self.didReachCheckpoint = didReachCheckpoint
    }

    func review(
        projectID: UUID,
        proposalID: UUID,
        action: WorkStateTransitionReviewAction
    ) async -> WorkStateTransitionReviewResult {
        if let intent = await pendingIntent(
            projectID: projectID,
            operationID: proposalID,
            operationKind: .proposal
        ) {
            return action == .approve
                ? await resume(intent)
                : .refused(.terminalVerdictConflict)
        }

        let proposal: WorkStateTransitionProposal
        let allProposals: [WorkStateTransitionProposal]
        do {
            let loaded = try await transitionRepository.allProposals()
            guard let found = loaded.first(where: {
                $0.id == proposalID
            }) else {
                return .refused(.proposalNotFound)
            }
            proposal = found
            allProposals = loaded
        } catch {
            return .refused(.reviewPersistenceFailed)
        }
        guard proposal.projectID == projectID else { return .refused(.projectMismatch) }

        switch (proposal.reviewStatus, action) {
        case (.approved, .approve): return .alreadyApplied
        case (.rejected, .reject): return .alreadyRejected
        case (.approved, .reject), (.rejected, .approve):
            return .refused(.terminalVerdictConflict)
        case (.pendingReview, .reject):
            return await persistRejection(projectID: projectID, proposalID: proposalID)
        case (.pendingReview, .approve):
            break
        }

        let terminalReviews = terminalReviewBatch(for: proposal, allProposals: allProposals)
        if let reason = validate(
            terminalReviews,
            projectID: projectID,
            against: allProposals
        ) {
            return .refused(reason)
        }

        let reviewedAt = now()
        let intent = WorkStateTransitionApplyIntent.proposal(
            projectID: projectID,
            proposalID: proposalID,
            terminalReviews: terminalReviews,
            reviewedAt: reviewedAt
        )
        let project: Project
        do {
            guard let loaded = try await projectRepository.project(id: projectID) else {
                return .refused(.projectNotFound)
            }
            project = loaded
        } catch {
            return .refused(.projectPersistenceFailed)
        }
        var updated = project
        switch apply(proposal, to: &updated, reviewedAt: reviewedAt) {
        case .failure(let reason): return .refused(reason)
        case .success(let changed):
            if changed { updated.updatedAt = reviewedAt }
        }

        switch await prepare(intent) {
        case .success:
            didReachCheckpoint(.intentStored)
        case .failure(let reason):
            return .refused(reason)
        }
        return await persistProjectAndFinalize(updated, intent: intent)
    }

    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection
    ) async -> WorkStateTransitionAmbiguityReviewResult {
        if let intent = await pendingIntent(
            projectID: projectID,
            operationID: groupID,
            operationKind: .ambiguity
        ) {
            guard intent.ambiguitySelection == selection else {
                return .refused(.terminalVerdictConflict)
            }
            return mapAmbiguityResult(await resume(intent))
        }

        let group: WorkStateAmbiguousMatchGroup
        let allProposals: [WorkStateTransitionProposal]
        do {
            guard let found = try await transitionRepository.allAmbiguousMatchGroups().first(where: {
                $0.id == groupID
            }) else {
                return .refused(.ambiguityGroupNotFound)
            }
            group = found
            if let existing = try await transitionRepository.ambiguityReview(groupID: groupID) {
                return existing.matches(selection)
                    ? .alreadyApplied
                    : .refused(.terminalVerdictConflict)
            }
            allProposals = try await transitionRepository.allProposals()
        } catch {
            return .refused(.reviewPersistenceFailed)
        }
        guard group.projectID == projectID else { return .refused(.projectMismatch) }
        guard group.accepts(selection) else { return .refused(.invalidAmbiguitySelection) }

        let reviewedAt = now()
        let intent = WorkStateTransitionApplyIntent.ambiguity(
            projectID: projectID,
            groupID: groupID,
            selection: selection,
            reviewedAt: reviewedAt
        )
        var project: Project
        do {
            guard let loaded = try await projectRepository.project(id: projectID) else {
                return .refused(.projectNotFound)
            }
            project = loaded
        } catch {
            return .refused(.projectPersistenceFailed)
        }
        switch applyAmbiguity(
            group,
            selection: selection,
            allProposals: allProposals,
            to: &project,
            reviewedAt: reviewedAt
        ) {
        case .failure(let reason): return .refused(reason)
        case .success(let changed):
            if changed { project.updatedAt = reviewedAt }
        }
        switch await prepare(intent) {
        case .success:
            didReachCheckpoint(.intentStored)
        case .failure(let reason):
            return .refused(reason)
        }
        return mapAmbiguityResult(await persistProjectAndFinalize(project, intent: intent))
    }

    /// Explicit launch/bootstrap recovery entry point. Manual Brief loading remains read-only.
    func recoverPendingApplies() async -> [WorkStateTransitionApplyRecoveryOutcome] {
        let intents: [WorkStateTransitionApplyIntent]
        do {
            intents = try await transitionRepository.pendingApplyIntents()
        } catch {
            return []
        }
        var outcomes: [WorkStateTransitionApplyRecoveryOutcome] = []
        for intent in intents {
            outcomes.append(WorkStateTransitionApplyRecoveryOutcome(
                operationID: intent.operationID,
                operationKind: intent.operationKind,
                result: await resume(intent)
            ))
        }
        return outcomes
    }

    private func pendingIntent(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind
    ) async -> WorkStateTransitionApplyIntent? {
        do {
            return try await transitionRepository.pendingApplyIntents().first {
                $0.projectID == projectID
                    && $0.operationID == operationID
                    && $0.operationKind == operationKind
            }
        } catch {
            return nil
        }
    }

    private func prepare(
        _ intent: WorkStateTransitionApplyIntent
    ) async -> Result<Void, WorkStateTransitionReviewRefusalReason> {
        do {
            switch try await transitionRepository.prepareApplyIntent(intent) {
            case .recorded, .alreadyRecorded:
                return .success(())
            case .refused:
                return .failure(.terminalVerdictConflict)
            }
        } catch {
            return .failure(.reviewPersistenceFailed)
        }
    }

    private func persistProjectAndFinalize(
        _ project: Project,
        intent: WorkStateTransitionApplyIntent
    ) async -> WorkStateTransitionReviewResult {
        let marker = WorkStateTransitionApplyMarker(
            projectID: intent.projectID,
            operationID: intent.operationID,
            operationKind: intent.operationKind,
            intentHash: intent.payloadHash,
            appliedAt: intent.reviewedAt
        )
        do {
            try await projectRepository.save(project, recording: marker)
        } catch {
            return .refused(.projectPersistenceFailed)
        }
        didReachCheckpoint(.projectAndMarkerStored)
        return await finalize(intent)
    }

    private func finalize(
        _ intent: WorkStateTransitionApplyIntent
    ) async -> WorkStateTransitionReviewResult {
        do {
            switch try await transitionRepository.finalizeApplyIntent(intent) {
            case .recorded:
                didReachCheckpoint(.verdictAndIntentCleanupStored)
                return .applied
            case .alreadyRecorded:
                didReachCheckpoint(.verdictAndIntentCleanupStored)
                return .alreadyApplied
            case .refused:
                return .projectSavedReviewPersistenceFailed
            }
        } catch {
            return .projectSavedReviewPersistenceFailed
        }
    }

    private func resume(
        _ intent: WorkStateTransitionApplyIntent
    ) async -> WorkStateTransitionReviewResult {
        guard intent.hasValidPayloadHash else { return .refused(.staleProposal) }
        do {
            if let marker = try await projectRepository.transitionApplyMarker(
                projectID: intent.projectID,
                operationID: intent.operationID,
                operationKind: intent.operationKind
            ) {
                guard marker.intentHash == intent.payloadHash else {
                    return .refused(.terminalVerdictConflict)
                }
                return await finalize(intent)
            }
        } catch {
            return .refused(.projectPersistenceFailed)
        }

        let project: Project
        do {
            guard let loaded = try await projectRepository.project(id: intent.projectID) else {
                return .refused(.projectNotFound)
            }
            project = loaded
        } catch {
            return .refused(.projectPersistenceFailed)
        }
        let allProposals: [WorkStateTransitionProposal]
        do {
            allProposals = try await transitionRepository.allProposals()
        } catch {
            return .refused(.reviewPersistenceFailed)
        }
        var updated = project
        let application: Result<Bool, WorkStateTransitionReviewRefusalReason>
        switch intent.operationKind {
        case .proposal:
            guard let proposal = allProposals.first(where: { $0.id == intent.operationID }) else {
                return .refused(.staleProposal)
            }
            guard proposal.projectID == intent.projectID else {
                return .refused(.projectMismatch)
            }
            if let reason = validate(
                intent.terminalReviews,
                projectID: intent.projectID,
                against: allProposals
            ) {
                return .refused(reason)
            }
            application = apply(proposal, to: &updated, reviewedAt: intent.reviewedAt)
        case .ambiguity:
            let groups: [WorkStateAmbiguousMatchGroup]
            do {
                groups = try await transitionRepository.allAmbiguousMatchGroups()
            } catch {
                return .refused(.reviewPersistenceFailed)
            }
            guard let group = groups.first(where: { $0.id == intent.operationID }),
                  group.projectID == intent.projectID,
                  let selection = intent.ambiguitySelection,
                  group.accepts(selection)
            else { return .refused(.staleProposal) }
            application = applyAmbiguity(
                group,
                selection: selection,
                allProposals: allProposals,
                to: &updated,
                reviewedAt: intent.reviewedAt
            )
        }
        switch application {
        case .failure(let reason): return .refused(reason)
        case .success(let changed):
            if changed { updated.updatedAt = intent.reviewedAt }
        }
        return await persistProjectAndFinalize(updated, intent: intent)
    }

    private func validate(
        _ reviews: [WorkStateTransitionTerminalReview],
        projectID: UUID,
        against proposals: [WorkStateTransitionProposal]
    ) -> WorkStateTransitionReviewRefusalReason? {
        guard !reviews.isEmpty else { return .staleProposal }
        for review in reviews {
            guard let row = proposals.first(where: { $0.id == review.proposalID }) else {
                return .staleProposal
            }
            guard row.projectID == projectID else { return .projectMismatch }
            let expected = review.verdict.reviewStatus
            if row.reviewStatus != .pendingReview && row.reviewStatus != expected {
                return .terminalVerdictConflict
            }
        }
        return nil
    }

    private func applyAmbiguity(
        _ group: WorkStateAmbiguousMatchGroup,
        selection: WorkStateAmbiguousMatchSelection,
        allProposals: [WorkStateTransitionProposal],
        to project: inout Project,
        reviewedAt: Date
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        switch selection {
        case .priorCandidate(let priorID):
            guard let proposal = allProposals.first(where: {
                $0.projectID == group.projectID
                    && $0.workStateKind == group.workStateKind
                    && $0.currentObjectID == group.incomingObjectID
                    && $0.previousStateID == priorID
            }) else { return .failure(.staleProposal) }
            return apply(proposal, to: &project, reviewedAt: reviewedAt)
        case .new:
            guard let reference = evidenceReference(
                kind: group.workStateKind,
                id: group.incomingObjectID,
                in: project
            ), evidenceReferenceExists(reference, in: project) else {
                return .failure(.evidenceNoLongerExists)
            }
            return approveCurrent(
                kind: group.workStateKind,
                id: group.incomingObjectID,
                sourceMeetingID: group.sourceMeetingID,
                in: &project,
                reviewedAt: reviewedAt,
                requirePending: true
            )
        }
    }

    private func mapAmbiguityResult(
        _ result: WorkStateTransitionReviewResult
    ) -> WorkStateTransitionAmbiguityReviewResult {
        switch result {
        case .applied: return .applied
        case .alreadyApplied: return .alreadyApplied
        case .projectSavedReviewPersistenceFailed:
            return .projectSavedReviewPersistenceFailed
        case .refused(let reason): return .refused(reason)
        case .rejected, .alreadyRejected:
            return .refused(.terminalVerdictConflict)
        }
    }

    private func persistRejection(
        projectID: UUID,
        proposalID: UUID
    ) async -> WorkStateTransitionReviewResult {
        do {
            switch try await transitionRepository.recordTerminalReview(
                projectID: projectID, proposalID: proposalID, verdict: .rejected
            ) {
            case .recorded: return .rejected
            case .alreadyRecorded: return .alreadyRejected
            case .refused(let reason): return .refused(map(reason))
            }
        } catch {
            return .refused(.reviewPersistenceFailed)
        }
    }

    private func apply(
        _ proposal: WorkStateTransitionProposal,
        to project: inout Project,
        reviewedAt: Date
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard proposal.projectID == project.id else { return .failure(.projectMismatch) }
        guard WorkStateTransitionMatrix.supports(
            proposal.transitionKind, for: proposal.workStateKind
        ) else { return .failure(.unsupportedTransition) }
        let expectedDedup = WorkStateTransitionProposal.dedupKey(
            projectID: proposal.projectID,
            workStateKind: proposal.workStateKind,
            transitionKind: proposal.transitionKind,
            previousStateID: proposal.previousStateID,
            currentObjectID: proposal.currentObjectID
        )
        guard proposal.dedupKey == expectedDedup,
              proposal.id == WorkStateTransitionProposal.deterministicID(forDedupKey: expectedDedup)
        else { return .failure(.staleProposal) }

        if proposal.basis != .overdueApprovedDueDate {
            guard canonicalEvidenceExists(for: proposal, in: project)
            else { return .failure(.evidenceNoLongerExists) }
        }

        switch proposal.transitionKind {
        case .new:
            guard proposal.previousStateID == nil, let currentID = proposal.currentObjectID else {
                return .failure(.staleProposal)
            }
            return approveCurrent(
                kind: proposal.workStateKind,
                id: currentID,
                sourceMeetingID: proposal.sourceMeetingID,
                in: &project,
                reviewedAt: reviewedAt,
                requirePending: true
            )
        case .same:
            return consumeSame(proposal, in: &project)
        case .changed:
            return applyChanged(proposal, in: &project, reviewedAt: reviewedAt)
        case .completed:
            return applyCompleted(proposal, in: &project, reviewedAt: reviewedAt)
        case .delayed:
            return applyDelayed(proposal, in: &project)
        case .resolved:
            return applyResolved(proposal, in: &project, reviewedAt: reviewedAt)
        }
    }

    private func consumeSame(
        _ proposal: WorkStateTransitionProposal,
        in project: inout Project
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard let previousID = proposal.previousStateID,
              let currentID = proposal.currentObjectID,
              previousID != currentID
        else { return .failure(.staleProposal) }
        guard objectProjectMatches(kind: proposal.workStateKind, id: previousID, in: project),
              objectProjectMatches(kind: proposal.workStateKind, id: currentID, in: project)
        else { return .failure(.crossProjectObject) }
        guard priorIsApproved(kind: proposal.workStateKind, id: previousID, in: project),
              currentIsPending(kind: proposal.workStateKind, id: currentID, in: project)
        else { return .failure(.staleProposal) }
        remove(kind: proposal.workStateKind, id: currentID, from: &project)
        return .success(true)
    }

    private func applyChanged(
        _ proposal: WorkStateTransitionProposal,
        in project: inout Project,
        reviewedAt: Date
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard let previousID = proposal.previousStateID,
              let currentID = proposal.currentObjectID,
              previousID != currentID
        else { return .failure(.staleProposal) }

        switch proposal.workStateKind {
        case .decision:
            guard let priorIndex = project.decisions.firstIndex(where: { $0.id == previousID }),
                  let currentIndex = project.decisions.firstIndex(where: { $0.id == currentID }),
                  ApprovedWorkStatePolicy.isApproved(project.decisions[priorIndex]),
                  PendingAIProposalPolicy.isPending(project.decisions[currentIndex])
            else { return .failure(.staleProposal) }
            let current = project.decisions[currentIndex]
            guard current.projectID == project.id,
                  project.decisions[priorIndex].projectID == project.id
            else { return .failure(.crossProjectObject) }
            project.decisions[priorIndex].statement = current.statement
            project.decisions[priorIndex].rationale = current.rationale
            project.decisions[priorIndex].evidence = current.evidence
            project.decisions[priorIndex].confidence = current.confidence
            project.decisions[priorIndex].updatedAt = reviewedAt
            project.decisions.remove(at: currentIndex)
        case .actionItem:
            guard let priorIndex = project.actionItems.firstIndex(where: { $0.id == previousID }),
                  let currentIndex = project.actionItems.firstIndex(where: { $0.id == currentID }),
                  ApprovedWorkStatePolicy.isApproved(project.actionItems[priorIndex]),
                  PendingAIProposalPolicy.isPending(project.actionItems[currentIndex])
            else { return .failure(.staleProposal) }
            let current = project.actionItems[currentIndex]
            guard current.projectID == project.id,
                  project.actionItems[priorIndex].projectID == project.id
            else { return .failure(.crossProjectObject) }
            project.actionItems[priorIndex].title = current.title
            project.actionItems[priorIndex].details = current.details
            project.actionItems[priorIndex].assigneeID = current.assigneeID
            project.actionItems[priorIndex].dueDate = current.dueDate
            project.actionItems[priorIndex].evidence = current.evidence
            project.actionItems[priorIndex].confidence = current.confidence
            project.actionItems[priorIndex].proposedAssigneeAttribution = current.proposedAssigneeAttribution
            project.actionItems[priorIndex].updatedAt = reviewedAt
            project.actionItems.remove(at: currentIndex)
        case .openQuestion:
            guard let priorIndex = project.openQuestions.firstIndex(where: { $0.id == previousID }),
                  let currentIndex = project.openQuestions.firstIndex(where: { $0.id == currentID }),
                  ApprovedWorkStatePolicy.isApproved(project.openQuestions[priorIndex]),
                  PendingAIProposalPolicy.isPending(project.openQuestions[currentIndex])
            else { return .failure(.staleProposal) }
            let current = project.openQuestions[currentIndex]
            guard current.projectID == project.id,
                  project.openQuestions[priorIndex].projectID == project.id
            else { return .failure(.crossProjectObject) }
            project.openQuestions[priorIndex].question = current.question
            project.openQuestions[priorIndex].evidence = current.evidence
            project.openQuestions[priorIndex].confidence = current.confidence
            project.openQuestions.remove(at: currentIndex)
        case .agendaItem:
            return .failure(.unsupportedTransition)
        }
        return .success(true)
    }

    private func applyCompleted(
        _ proposal: WorkStateTransitionProposal,
        in project: inout Project,
        reviewedAt: Date
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard proposal.workStateKind == .actionItem,
              let previousID = proposal.previousStateID,
              let priorIndex = project.actionItems.firstIndex(where: { $0.id == previousID }),
              ApprovedWorkStatePolicy.isApproved(project.actionItems[priorIndex]),
              project.actionItems[priorIndex].projectID == project.id
        else { return .failure(.staleProposal) }

        // A meeting that only reported "that one is done" produced no incoming duplicate, so there
        // is nothing to consume. Absence is the shape of this proposal, not evidence that it went
        // stale — treating it as stale would make the prior-target path permanently unapprovable.
        guard let currentID = proposal.currentObjectID else {
            project.actionItems[priorIndex].status = .completed
            project.actionItems[priorIndex].updatedAt = reviewedAt
            return .success(true)
        }

        guard let current = project.actionItems.first(where: { $0.id == currentID }),
              PendingAIProposalPolicy.isPending(current)
        else { return .failure(.staleProposal) }
        guard current.projectID == project.id else { return .failure(.crossProjectObject) }
        project.actionItems[priorIndex].status = .completed
        project.actionItems[priorIndex].updatedAt = reviewedAt
        project.actionItems.removeAll { $0.id == currentID }
        return .success(true)
    }

    private func applyDelayed(
        _ proposal: WorkStateTransitionProposal,
        in project: inout Project
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard proposal.workStateKind == .actionItem,
              let previousID = proposal.previousStateID,
              let prior = project.actionItems.first(where: { $0.id == previousID }),
              prior.projectID == project.id,
              ApprovedWorkStatePolicy.isApproved(prior)
        else { return .failure(.staleProposal) }

        if proposal.basis == .overdueApprovedDueDate {
            guard proposal.currentObjectID == nil,
                  proposal.progressDisposition == nil,
                  let dueDate = prior.dueDate,
                  let meeting = project.meetings.first(where: { $0.id == proposal.sourceMeetingID }),
                  dueDate < meeting.occurredAt
            else { return .failure(.staleProposal) }
            return .success(false)
        }

        guard proposal.basis == .structuredProgressSignal,
              proposal.progressDisposition != nil
        else { return .failure(.staleProposal) }

        // Same as `completed`: a prior-target deferral or block has no incoming duplicate to
        // consume. Either way the prior item's status and due date are left exactly as they were —
        // "we pushed it" is a fact for the next meeting's briefing, not a licence to move a date.
        guard let currentID = proposal.currentObjectID else { return .success(false) }

        guard let current = project.actionItems.first(where: { $0.id == currentID }),
              current.projectID == project.id,
              PendingAIProposalPolicy.isPending(current)
        else { return .failure(.staleProposal) }
        project.actionItems.removeAll { $0.id == currentID }
        return .success(true)
    }

    private func applyResolved(
        _ proposal: WorkStateTransitionProposal,
        in project: inout Project,
        reviewedAt: Date
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        guard proposal.workStateKind == .openQuestion,
              let previousID = proposal.previousStateID,
              let currentID = proposal.currentObjectID,
              let questionIndex = project.openQuestions.firstIndex(where: { $0.id == previousID }),
              project.openQuestions[questionIndex].projectID == project.id,
              ApprovedWorkStatePolicy.isApproved(project.openQuestions[questionIndex])
        else { return .failure(.staleProposal) }
        let resolutionRelations = proposal.relations.filter {
            $0.kind == .resolvedBy || $0.kind == .carriedToAgenda
        }
        guard resolutionRelations.count == 1,
              let relation = resolutionRelations.first,
              relation.relatedObjectID == currentID,
              (relation.kind != .carriedToAgenda || relation.relatedKind == .agendaItem)
        else { return .failure(.staleProposal) }

        switch approveCurrent(
            kind: relation.relatedKind,
            id: currentID,
            sourceMeetingID: proposal.sourceMeetingID,
            in: &project,
            reviewedAt: reviewedAt,
            requirePending: false
        ) {
        case .failure(let reason): return .failure(reason)
        case .success: break
        }
        project.openQuestions[questionIndex].status = .resolved
        project.openQuestions[questionIndex].resolvedAt = reviewedAt
        return .success(true)
    }

    private func approveCurrent(
        kind: WorkStateKind,
        id: UUID,
        sourceMeetingID: UUID,
        in project: inout Project,
        reviewedAt: Date,
        requirePending: Bool
    ) -> Result<Bool, WorkStateTransitionReviewRefusalReason> {
        switch kind {
        case .decision:
            guard let index = project.decisions.firstIndex(where: { $0.id == id }) else {
                return .failure(.staleProposal)
            }
            guard project.decisions[index].projectID == project.id else {
                return .failure(.crossProjectObject)
            }
            if ApprovedWorkStatePolicy.isApproved(project.decisions[index]) && !requirePending {
                return .success(false)
            }
            guard PendingAIProposalPolicy.isPending(project.decisions[index]),
                  project.decisions[index].meetingID == sourceMeetingID
            else { return .failure(.staleProposal) }
            project.decisions[index].status = .confirmed
            project.decisions[index].updatedAt = reviewedAt
        case .actionItem:
            guard let index = project.actionItems.firstIndex(where: { $0.id == id }) else {
                return .failure(.staleProposal)
            }
            guard project.actionItems[index].projectID == project.id else {
                return .failure(.crossProjectObject)
            }
            if ApprovedWorkStatePolicy.isApproved(project.actionItems[index]) && !requirePending {
                return .success(false)
            }
            guard PendingAIProposalPolicy.isPending(project.actionItems[index]),
                  project.actionItems[index].meetingID == sourceMeetingID
            else { return .failure(.staleProposal) }
            project.actionItems[index].status = .confirmed
            project.actionItems[index].updatedAt = reviewedAt
        case .openQuestion:
            guard let index = project.openQuestions.firstIndex(where: { $0.id == id }) else {
                return .failure(.staleProposal)
            }
            guard project.openQuestions[index].projectID == project.id else {
                return .failure(.crossProjectObject)
            }
            if ApprovedWorkStatePolicy.isApproved(project.openQuestions[index]) && !requirePending {
                return .success(false)
            }
            guard PendingAIProposalPolicy.isPending(project.openQuestions[index]),
                  project.openQuestions[index].meetingID == sourceMeetingID
            else { return .failure(.staleProposal) }
            project.openQuestions[index].status = .open
            project.openQuestions[index].reviewedAt = reviewedAt
        case .agendaItem:
            guard let index = project.nextAgenda.firstIndex(where: { $0.id == id }) else {
                return .failure(.staleProposal)
            }
            guard project.nextAgenda[index].projectID == project.id else {
                return .failure(.crossProjectObject)
            }
            if ApprovedWorkStatePolicy.isApproved(project.nextAgenda[index]) && !requirePending {
                return .success(false)
            }
            guard PendingAIProposalPolicy.isPending(project.nextAgenda[index]),
                  project.nextAgenda[index].sourceMeetingID == sourceMeetingID
            else { return .failure(.staleProposal) }
            project.nextAgenda[index].status = .pending
            project.nextAgenda[index].reviewedAt = reviewedAt
        }
        return .success(true)
    }

    private func canonicalEvidenceExists(
        for proposal: WorkStateTransitionProposal,
        in project: Project
    ) -> Bool {
        if let currentID = proposal.currentObjectID,
           let reference = currentEvidenceReference(for: proposal, currentID: currentID, in: project) {
            return evidenceReferenceExists(reference, in: project)
        }

        guard let evidence = proposal.evidence,
              let meeting = project.meetings.first(where: { $0.id == evidence.meetingID })
        else { return false }
        return meeting.transcriptSegments.contains {
            $0.id == evidence.transcriptSegmentID && $0.meetingID == evidence.meetingID
        }
    }

    private func currentEvidenceReference(
        for proposal: WorkStateTransitionProposal,
        currentID: UUID,
        in project: Project
    ) -> EvidenceReference? {
        let kind = proposal.relations.first(where: { $0.relatedObjectID == currentID })?.relatedKind
            ?? proposal.workStateKind
        return evidenceReference(kind: kind, id: currentID, in: project)
    }

    private func evidenceReference(
        kind: WorkStateKind,
        id: UUID,
        in project: Project
    ) -> EvidenceReference? {
        switch kind {
        case .decision: return project.decisions.first(where: { $0.id == id })?.evidence
        case .actionItem: return project.actionItems.first(where: { $0.id == id })?.evidence
        case .openQuestion: return project.openQuestions.first(where: { $0.id == id })?.evidence
        case .agendaItem: return project.nextAgenda.first(where: { $0.id == id })?.evidence
        }
    }

    private func evidenceReferenceExists(_ reference: EvidenceReference, in project: Project) -> Bool {
        guard !reference.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let meeting = project.meetings.first(where: { $0.id == reference.meetingID }),
              let segment = meeting.transcriptSegments.first(where: {
                  $0.id == reference.transcriptSegmentID && $0.meetingID == reference.meetingID
              })
        else { return false }
        return segment.text.contains(reference.quote)
    }

    private func priorIsApproved(kind: WorkStateKind, id: UUID, in project: Project) -> Bool {
        switch kind {
        case .decision:
            return project.decisions.first(where: { $0.id == id }).map {
                $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
            } ?? false
        case .actionItem:
            return project.actionItems.first(where: { $0.id == id }).map {
                $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
            } ?? false
        case .openQuestion:
            return project.openQuestions.first(where: { $0.id == id }).map {
                $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
            } ?? false
        case .agendaItem:
            return project.nextAgenda.first(where: { $0.id == id }).map {
                $0.projectID == project.id && ApprovedWorkStatePolicy.isApproved($0)
            } ?? false
        }
    }

    private func currentIsPending(kind: WorkStateKind, id: UUID, in project: Project) -> Bool {
        switch kind {
        case .decision:
            return project.decisions.first(where: { $0.id == id }).map {
                $0.projectID == project.id && PendingAIProposalPolicy.isPending($0)
            } ?? false
        case .actionItem:
            return project.actionItems.first(where: { $0.id == id }).map {
                $0.projectID == project.id && PendingAIProposalPolicy.isPending($0)
            } ?? false
        case .openQuestion:
            return project.openQuestions.first(where: { $0.id == id }).map {
                $0.projectID == project.id && PendingAIProposalPolicy.isPending($0)
            } ?? false
        case .agendaItem:
            return project.nextAgenda.first(where: { $0.id == id }).map {
                $0.projectID == project.id && PendingAIProposalPolicy.isPending($0)
            } ?? false
        }
    }

    private func objectProjectMatches(
        kind: WorkStateKind,
        id: UUID,
        in project: Project
    ) -> Bool {
        switch kind {
        case .decision: return project.decisions.first(where: { $0.id == id })?.projectID == project.id
        case .actionItem: return project.actionItems.first(where: { $0.id == id })?.projectID == project.id
        case .openQuestion: return project.openQuestions.first(where: { $0.id == id })?.projectID == project.id
        case .agendaItem: return project.nextAgenda.first(where: { $0.id == id })?.projectID == project.id
        }
    }

    private func remove(kind: WorkStateKind, id: UUID, from project: inout Project) {
        switch kind {
        case .decision: project.decisions.removeAll { $0.id == id }
        case .actionItem: project.actionItems.removeAll { $0.id == id }
        case .openQuestion: project.openQuestions.removeAll { $0.id == id }
        case .agendaItem: project.nextAgenda.removeAll { $0.id == id }
        }
    }

    private func terminalReviewBatch(
        for proposal: WorkStateTransitionProposal,
        allProposals: [WorkStateTransitionProposal]
    ) -> [WorkStateTransitionTerminalReview] {
        var verdicts: [UUID: WorkStateTransitionTerminalVerdict] = [proposal.id: .approved]

        if proposal.workStateKind == .actionItem,
           proposal.transitionKind == .completed || proposal.transitionKind == .delayed {
            for sibling in allProposals where sibling.projectID == proposal.projectID
                && sibling.id != proposal.id
                && sibling.workStateKind == .actionItem
                && sibling.previousStateID == proposal.previousStateID
                && sibling.currentObjectID == proposal.currentObjectID
                && (sibling.transitionKind == .same || sibling.transitionKind == .changed) {
                verdicts[sibling.id] = .rejected
            }
        }

        if proposal.transitionKind == .resolved,
           let targetID = proposal.currentObjectID,
           let targetKind = proposal.relations.first(where: {
               $0.relatedObjectID == targetID
                    && ($0.kind == .resolvedBy || $0.kind == .carriedToAgenda)
           })?.relatedKind {
            for sibling in allProposals where sibling.projectID == proposal.projectID
                && sibling.id != proposal.id
                && sibling.workStateKind == targetKind
                && sibling.currentObjectID == targetID {
                verdicts[sibling.id] = sibling.transitionKind == .new ? .approved : .rejected
            }
        }

        return verdicts.map {
            WorkStateTransitionTerminalReview(proposalID: $0.key, verdict: $0.value)
        }.sorted {
            $0.proposalID.uuidString.lowercased() < $1.proposalID.uuidString.lowercased()
        }
    }

    private func map(
        _ reason: WorkStateTransitionReviewWriteRefusalReason
    ) -> WorkStateTransitionReviewRefusalReason {
        switch reason {
        case .unknownProposal: return .proposalNotFound
        case .unknownAmbiguityGroup: return .ambiguityGroupNotFound
        case .projectMismatch: return .projectMismatch
        case .terminalVerdictConflict: return .terminalVerdictConflict
        case .invalidAmbiguitySelection: return .invalidAmbiguitySelection
        case .incompleteAmbiguityGroup: return .staleProposal
        }
    }
}
