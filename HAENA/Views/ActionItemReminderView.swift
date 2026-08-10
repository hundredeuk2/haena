import AppKit
import SwiftUI

struct ActionItemReminderView: View {
    let project: Project
    let actionItem: ActionItem
    let service: ActionItemReminderService
    let existingReminder: ActionItemReminder?
    let onChanged: () async -> Void
    let onClose: () -> Void

    @State private var fireAt: Date
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsNotificationSettings = false

    private let dateFormatter = MeetingDateFormatter()

    init(
        project: Project,
        actionItem: ActionItem,
        service: ActionItemReminderService,
        existingReminder: ActionItemReminder?,
        onChanged: @escaping () async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.project = project
        self.actionItem = actionItem
        self.service = service
        self.existingReminder = existingReminder
        self.onChanged = onChanged
        self.onClose = onClose
        _fireAt = State(
            initialValue: existingReminder?.fireAt
                ?? service.suggestedFireDate(for: actionItem.dueDate ?? Date())
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingReminder?.status == .scheduled ? "알림 변경" : "알림 설정")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(actionItem.title)
                    .font(.title3)
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dueDate = actionItem.dueDate {
                    Text("마감 \(dateFormatter.string(from: dueDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let meeting = project.meetings.first(where: { $0.id == actionItem.meetingID }) {
                    Text("근거 회의 · \(meeting.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DatePicker(
                "알림 시각",
                selection: $fireAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .accessibilityIdentifier("action-item-reminder-date-picker")

            Text("추천 시각은 규칙으로 계산되며, 이 화면에서 확인한 시각만 예약됩니다. 임박했거나 지난 시각은 변경하지 않고 다시 선택하도록 알려드립니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("action-item-reminder-error")
                    if showsNotificationSettings {
                        Button("시스템 알림 설정 열기") {
                            openNotificationSettings()
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("open-notification-settings-button")
                    }
                }
            }

            HStack {
                if existingReminder?.status == .scheduled {
                    Button("알림 취소", role: .destructive) {
                        Task { await cancel() }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("cancel-action-item-reminder-button")
                }

                Spacer()

                Button("닫기") { onClose() }
                    .disabled(isWorking)

                Button(existingReminder?.status == .scheduled ? "변경" : "예약") {
                    Task { await schedule() }
                }
                .keyboardShortcut(.defaultAction)
                // Keep this tappable if time passes while the sheet is open, so the service can
                // explain the stale selection instead of leaving a silently disabled button.
                .disabled(isWorking)
                .accessibilityIdentifier("schedule-action-item-reminder-button")
            }
        }
        .padding(24)
        .frame(minWidth: 430)
    }

    private func schedule() async {
        isWorking = true
        errorMessage = nil
        showsNotificationSettings = false
        defer { isWorking = false }
        do {
            _ = try await service.schedule(
                projectID: project.id,
                actionItemID: actionItem.id,
                fireAt: fireAt
            )
            await onChanged()
            onClose()
        } catch ActionItemReminderError.permissionDenied {
            errorMessage = "알림 권한이 꺼져 있습니다. 시스템 설정에서 HAE.NA 알림을 허용해주세요."
            showsNotificationSettings = true
        } catch ActionItemReminderError.fireDateNotInFuture {
            errorMessage = "선택한 시각이 이미 지났습니다. 다음 분 이후로 다시 선택해주세요."
        } catch ActionItemReminderError.fireDateTooSoon {
            errorMessage = "선택한 시각이 너무 임박했습니다. 다음 분 이후로 다시 선택해주세요."
        } catch ActionItemReminderError.ineligible {
            errorMessage = "이 업무는 더 이상 알림을 예약할 수 있는 상태가 아닙니다."
        } catch {
            errorMessage = "알림을 예약하지 못했습니다. 기존 예약은 유지됩니다."
        }
    }

    private func cancel() async {
        isWorking = true
        errorMessage = nil
        showsNotificationSettings = false
        defer { isWorking = false }
        do {
            _ = try await service.cancel(actionItemID: actionItem.id)
            await onChanged()
            onClose()
        } catch {
            errorMessage = "알림을 취소하지 못했습니다."
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct ReminderDateDisplay {
    private let formatter: DateFormatter

    init(timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "ko_KR")) {
        formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M월 d일 a h:mm"
    }

    func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
