import Foundation

enum ActionItemReminderStatus: String, Codable, Equatable, Sendable {
    case scheduled
    case delivered
    case cancelled
}

enum ActionItemReminderCancellationReason: String, Codable, Equatable, Sendable {
    case userCancelled
    case actionItemCompleted
    case actionItemCancelled
    case actionItemDeleted
    case projectDeleted
    case noLongerAssignedToUser
    case dueDateRemoved
    case notificationPermissionDenied
}

/// The first deliberately narrow Agent Job: one user-approved local reminder for one ActionItem.
///
/// It is stored separately from projects so adding or repairing the agent runtime cannot put the
/// user's meeting data at risk. `fireAt` is the time the user approved; a later due-date edit does
/// not silently rewrite it.
struct ActionItemReminder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let actionItemID: UUID
    var fireAt: Date
    var status: ActionItemReminderStatus
    let createdAt: Date
    var updatedAt: Date
    var cancellationReason: ActionItemReminderCancellationReason?

    var notificationIdentifier: String {
        Self.notificationIdentifier(for: actionItemID)
    }

    static func notificationIdentifier(for actionItemID: UUID) -> String {
        "haena.action-item-reminder.\(actionItemID.uuidString.lowercased())"
    }
}

struct ActionItemReminderStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var reminders: [ActionItemReminder]

    init(
        schemaVersion: Int = ActionItemReminderStoreFile.currentSchemaVersion,
        reminders: [ActionItemReminder] = []
    ) {
        self.schemaVersion = schemaVersion
        self.reminders = reminders
    }
}
