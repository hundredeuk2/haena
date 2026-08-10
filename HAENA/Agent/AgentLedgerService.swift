import Foundation

struct AgentLedgerService: Sendable {
    let repository: any AgentLedgerRepository
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        repository: any AgentLedgerRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    func events(limit: Int? = nil) async throws -> [AgentLedgerEvent] {
        try await repository.events(limit: limit)
    }

    /// Best-effort recording APIs never make the user-visible reminder operation fail. Callers
    /// should invoke them from their existing Task so disk work never blocks the main actor.
    func recordScheduled(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .scheduled,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor
        )
    }

    func recordRescheduled(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .rescheduled,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor
        )
    }

    func recordCancelled(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date? = nil,
        source: AgentLedgerCancellationSource,
        reason: AgentLedgerCancellationReason
    ) async {
        await record(
            type: .cancelled,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor,
            cancellation: AgentLedgerCancellation(source: source, reason: reason)
        )
    }

    func recordCancelled(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date? = nil,
        reason: ActionItemReminderCancellationReason
    ) async {
        await recordCancelled(
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor,
            source: reason == .userCancelled ? .user : .policy,
            reason: AgentLedgerCancellationReason(reason)
        )
    }

    func recordPresentedForeground(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .presentedForeground,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor
        )
    }

    func recordOpenedFromNotification(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .openedFromNotification,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor
        )
    }

    func recordFireTimeReached(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .fireTimeReached,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor,
            derivedSourceOccurredAt: scheduledFor
        )
    }

    func recordTaskCompletedAfterReminder(
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date
    ) async {
        await record(
            type: .taskCompletedAfterReminder,
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            scheduledFor: scheduledFor,
            derivedSourceOccurredAt: scheduledFor
        )
    }

    @discardableResult
    func setFeedback(
        _ value: AgentLedgerFeedback,
        for event: AgentLedgerEvent
    ) async throws -> AgentLedgerEvent {
        let timestamp = now()
        let feedback = AgentLedgerEvent(
            id: makeID(),
            deduplicationKey: "feedback:\(event.reminderID.uuidString.lowercased())",
            reminderID: event.reminderID,
            projectID: event.projectID,
            actionItemID: event.actionItemID,
            type: .feedback,
            occurredAt: timestamp,
            scheduledFor: event.scheduledFor,
            feedback: value
        )
        return try await repository.upsertFeedback(feedback)
    }

    func clearFeedback(for reminderID: UUID) async throws {
        try await repository.clearFeedback(for: reminderID)
    }

    func clearAll() async throws {
        try await repository.clear(at: now())
    }

    private func record(
        type: AgentLedgerEventType,
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        scheduledFor: Date?,
        cancellation: AgentLedgerCancellation? = nil,
        derivedSourceOccurredAt: Date? = nil
    ) async {
        let timestamp = now()
        let event = AgentLedgerEvent(
            id: makeID(),
            deduplicationKey: Self.deduplicationKey(
                type: type,
                reminderID: reminderID,
                scheduledFor: scheduledFor,
                cancellation: cancellation
            ),
            reminderID: reminderID,
            projectID: projectID,
            actionItemID: actionItemID,
            type: type,
            occurredAt: timestamp,
            scheduledFor: scheduledFor,
            cancellation: cancellation
        )
        if let derivedSourceOccurredAt {
            _ = try? await repository.appendDerived(
                event,
                sourceOccurredAt: derivedSourceOccurredAt
            )
        } else {
            _ = try? await repository.append(event)
        }
    }

    private static func deduplicationKey(
        type: AgentLedgerEventType,
        reminderID: UUID,
        scheduledFor: Date?,
        cancellation: AgentLedgerCancellation?
    ) -> String {
        let fireToken = scheduledFor.map { String(Int64(($0.timeIntervalSince1970 * 1_000).rounded())) } ?? "none"
        let cancellationToken = cancellation.map { "\($0.source.rawValue):\($0.reason.rawValue)" } ?? "none"
        return "\(type.rawValue):\(reminderID.uuidString.lowercased()):\(fireToken):\(cancellationToken)"
    }
}
