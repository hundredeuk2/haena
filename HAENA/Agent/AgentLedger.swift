import Foundation

enum AgentLedgerEventType: String, Codable, Equatable, Sendable, CaseIterable {
    case scheduled
    case rescheduled
    case cancelled
    case presentedForeground
    case openedFromNotification
    case fireTimeReached
    case taskCompletedAfterReminder
    case feedback
}

enum AgentLedgerFeedback: String, Codable, Equatable, Sendable, CaseIterable {
    case helpful
    case tooEarly
    case tooLate
    case unnecessary
}

enum AgentLedgerCancellationSource: String, Codable, Equatable, Sendable {
    case user
    case policy
}

/// A deliberately finite reason list. The ledger never accepts free-form text because a title,
/// transcript fragment, participant name, or notification body must not accidentally enter it.
enum AgentLedgerCancellationReason: String, Codable, Equatable, Sendable {
    case userCancelled
    case actionItemCompleted
    case actionItemCancelled
    case actionItemDeleted
    case projectDeleted
    case noLongerAssignedToUser
    case dueDateRemoved
    case notificationPermissionDenied

    init(_ reason: ActionItemReminderCancellationReason) {
        switch reason {
        case .userCancelled: self = .userCancelled
        case .actionItemCompleted: self = .actionItemCompleted
        case .actionItemCancelled: self = .actionItemCancelled
        case .actionItemDeleted: self = .actionItemDeleted
        case .projectDeleted: self = .projectDeleted
        case .noLongerAssignedToUser: self = .noLongerAssignedToUser
        case .dueDateRemoved: self = .dueDateRemoved
        case .notificationPermissionDenied: self = .notificationPermissionDenied
        }
    }
}

struct AgentLedgerCancellation: Codable, Equatable, Sendable {
    let source: AgentLedgerCancellationSource
    let reason: AgentLedgerCancellationReason
}

/// Privacy-minimal evidence for the private reminder loop.
///
/// This type intentionally has no arbitrary String payload. Project names, task titles, meeting
/// text, notification content, people, and model input/output stay in their source stores.
struct AgentLedgerEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let deduplicationKey: String
    let reminderID: UUID
    let projectID: UUID
    let actionItemID: UUID
    let type: AgentLedgerEventType
    let occurredAt: Date
    let scheduledFor: Date?
    let cancellation: AgentLedgerCancellation?
    let feedback: AgentLedgerFeedback?

    init(
        id: UUID,
        deduplicationKey: String,
        reminderID: UUID,
        projectID: UUID,
        actionItemID: UUID,
        type: AgentLedgerEventType,
        occurredAt: Date,
        scheduledFor: Date? = nil,
        cancellation: AgentLedgerCancellation? = nil,
        feedback: AgentLedgerFeedback? = nil
    ) {
        self.id = id
        self.deduplicationKey = deduplicationKey
        self.reminderID = reminderID
        self.projectID = projectID
        self.actionItemID = actionItemID
        self.type = type
        self.occurredAt = occurredAt
        self.scheduledFor = scheduledFor
        self.cancellation = cancellation
        self.feedback = feedback
    }
}

struct AgentLedgerStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Privacy deletion boundary. Reconcile-derived facts whose source fire time is at or before
    /// this value stay deleted, while genuinely new callbacks and future fires can be recorded.
    var clearedAt: Date?
    var events: [AgentLedgerEvent]

    init(
        schemaVersion: Int = AgentLedgerStoreFile.currentSchemaVersion,
        clearedAt: Date? = nil,
        events: [AgentLedgerEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.clearedAt = clearedAt
        self.events = events
    }
}
