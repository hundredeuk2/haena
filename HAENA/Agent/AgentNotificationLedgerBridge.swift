import Foundation

/// Resolves a notification callback back to the one persisted reminder it names.
///
/// The OS callback carries notification content too, but none of that text enters the ledger. A
/// malformed, stale, or foreign identifier is ignored rather than guessed from a title/body.
struct AgentNotificationLedgerBridge: Sendable {
    let reminderRepository: any ActionItemReminderRepository
    let ledger: AgentLedgerService

    func record(_ callback: LocalNotificationLifecycleCallback) async {
        let identifier = callback.identifier
        guard let actionItemID = Self.actionItemID(from: identifier),
              let callbackReminderID = callback.reminderID,
              let reminder = try? await reminderRepository.reminder(for: actionItemID),
              reminder.notificationIdentifier == identifier,
              reminder.id == callbackReminderID,
              reminder.status != .cancelled else {
            return
        }

        switch callback {
        case .presentedForeground:
            await ledger.recordPresentedForeground(
                reminderID: reminder.id,
                projectID: reminder.projectID,
                actionItemID: reminder.actionItemID,
                scheduledFor: reminder.fireAt
            )
        case .openedFromNotification:
            await ledger.recordOpenedFromNotification(
                reminderID: reminder.id,
                projectID: reminder.projectID,
                actionItemID: reminder.actionItemID,
                scheduledFor: reminder.fireAt
            )
        }
    }

    static func actionItemID(from identifier: String) -> UUID? {
        let prefix = "haena.action-item-reminder."
        guard identifier.hasPrefix(prefix) else { return nil }
        let token = String(identifier.dropFirst(prefix.count))
        guard !token.isEmpty, !token.contains(".") else { return nil }
        return UUID(uuidString: token)
    }
}
