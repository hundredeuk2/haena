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
    /// The task's due date moved after the user approved a fire time. The approved time is never
    /// rewritten to follow it, so the projection is retired and the user is asked to approve a new
    /// one against the new deadline.
    case dueDateChanged
    case notificationPermissionDenied
}

/// The first deliberately narrow Agent Job: one user-approved local reminder for one ActionItem.
///
/// It is stored separately from projects so adding or repairing the agent runtime cannot put the
/// user's meeting data at risk. `fireAt` is the time the user approved; a later due-date edit does
/// not silently rewrite it — reconcile retires the job as `dueDateChanged` and asks for a new
/// approval instead.
struct ActionItemReminder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let actionItemID: UUID
    var fireAt: Date
    /// The task's due date as it stood when the user approved `fireAt`, which is the only way to
    /// tell later that the deadline moved. Optional and additive on purpose: rows written before
    /// this field decode as nil, and nil means "approved before we recorded this" — unknown, never
    /// a mismatch — so a legacy job is never cancelled on a comparison it cannot make.
    var approvedDueDate: Date?
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
