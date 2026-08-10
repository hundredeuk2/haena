import Foundation

extension AgentLedgerFeedback {
    var label: String {
        switch self {
        case .helpful:
            return "도움 됐어요"
        case .tooEarly:
            return "너무 일러요"
        case .tooLate:
            return "너무 늦어요"
        case .unnecessary:
            return "필요 없었어요"
        }
    }
}

struct AgentLedgerRow: Identifiable, Equatable, Sendable {
    let event: AgentLedgerEvent
    let projectName: String
    let actionItemTitle: String
    let factLabel: String
    let acceptsFeedback: Bool
    var feedback: AgentLedgerFeedback?

    var id: UUID { event.id }
}

/// Keeps a feedback write failure attached to the one reminder row whose state did not change.
/// This small value boundary is independent of SwiftUI so row targeting stays unit-testable.
struct AgentLedgerFeedbackFailure: Equatable, Sendable {
    static let copy = "피드백을 저장하지 못했습니다. 기존 선택은 유지됩니다."

    let reminderID: UUID

    func message(for row: AgentLedgerRow) -> String? {
        row.event.reminderID == reminderID ? Self.copy : nil
    }
}

enum AgentLedgerPresentation {
    static let deletedProjectName = "삭제된 프로젝트"
    static let deletedActionItemTitle = "삭제된 업무"

    /// Resolves live names without requiring referential integrity from an append-only record.
    /// Missing references never expose a UUID or make the entire history unreadable.
    static func rows(
        events: [AgentLedgerEvent],
        projects: [Project],
        dateFormatter: AgentLedgerDateFormatter = AgentLedgerDateFormatter()
    ) -> [AgentLedgerRow] {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var feedbackEventsByReminder: [UUID: AgentLedgerEvent] = [:]
        for event in events where event.type == .feedback && event.feedback != nil {
            guard let existing = feedbackEventsByReminder[event.reminderID] else {
                feedbackEventsByReminder[event.reminderID] = event
                continue
            }
            if isMoreRecent(event, existing) {
                feedbackEventsByReminder[event.reminderID] = event
            }
        }
        let feedbackByReminder = feedbackEventsByReminder.compactMapValues(\.feedback)
        var remindersWithFeedbackControl = Set<UUID>()

        return events
            .filter { $0.type != .feedback }
            .sorted(by: isMoreRecent)
            .map { event in
                let project = projectsByID[event.projectID]
                let actionItem = project?.actionItems.first(where: { $0.id == event.actionItemID })
                let acceptsFeedback = isFeedbackEligible(event.type)
                    && remindersWithFeedbackControl.insert(event.reminderID).inserted
                return AgentLedgerRow(
                    event: event,
                    projectName: project?.name ?? deletedProjectName,
                    actionItemTitle: actionItem?.title ?? deletedActionItemTitle,
                    factLabel: factLabel(for: event, dateFormatter: dateFormatter),
                    acceptsFeedback: acceptsFeedback,
                    feedback: acceptsFeedback ? feedbackByReminder[event.reminderID] : nil
                )
            }
    }

    static func factLabel(
        for event: AgentLedgerEvent,
        dateFormatter: AgentLedgerDateFormatter = AgentLedgerDateFormatter()
    ) -> String {
        switch event.type {
        case .scheduled:
            return datedFact("알림 예약됨", date: event.scheduledFor, formatter: dateFormatter)
        case .rescheduled:
            return datedFact("알림 변경됨", date: event.scheduledFor, formatter: dateFormatter)
        case .cancelled:
            switch event.cancellation?.source {
            case .user:
                return "사용자가 알림 예약 취소함"
            case .policy:
                return "상태에 따라 알림 예약 자동 취소됨"
            case nil:
                return "알림 예약 취소 기록됨"
            }
        case .presentedForeground:
            return "앱 사용 중 알림 표시 콜백 수신"
        case .openedFromNotification:
            return "알림 열기 응답 수신"
        case .fireTimeReached:
            return datedFact("예약 시각 지남", date: event.scheduledFor, formatter: dateFormatter)
        case .taskCompletedAfterReminder:
            return "알림 기록 뒤 업무 완료 처리됨"
        case .feedback:
            // Feedback events are folded into their related reminder row and never rendered alone.
            return "알림 피드백 저장됨"
        }
    }

    private static func datedFact(
        _ fact: String,
        date: Date?,
        formatter: AgentLedgerDateFormatter
    ) -> String {
        guard let date else { return "\(fact) · 예약 시각 없음" }
        return "\(fact) · \(formatter.string(from: date))"
    }

    private static func isFeedbackEligible(_ type: AgentLedgerEventType) -> Bool {
        switch type {
        case .presentedForeground, .openedFromNotification, .fireTimeReached, .taskCompletedAfterReminder:
            return true
        case .scheduled, .rescheduled, .cancelled, .feedback:
            return false
        }
    }

    private static func isMoreRecent(
        _ lhs: AgentLedgerEvent,
        _ rhs: AgentLedgerEvent
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct AgentLedgerDateFormatter: Sendable {
    let locale: Locale
    let timeZone: TimeZone

    init(
        locale: Locale = Locale(identifier: "ko_KR"),
        timeZone: TimeZone = .current
    ) {
        self.locale = locale
        self.timeZone = timeZone
    }

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M월 d일 a h:mm"
        return formatter.string(from: date)
    }
}
