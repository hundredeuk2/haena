import Foundation

enum ActionItemReminderEligibility: Equatable, Sendable {
    case eligible
    case notConfirmed
    case notAssignedToUser
    case dueDateMissing
}

enum ActionItemReminderError: Error, Equatable, Sendable {
    case projectNotFound
    case actionItemNotFound
    case ineligible(ActionItemReminderEligibility)
    case fireDateNotInFuture
    case fireDateTooSoon
    case permissionDenied
    case notificationFailure
    case storageFailure
}

struct ActionItemReminderService: Sendable {
    /// Enough room for repository and notification-center work without rejecting a normal
    /// minute-ahead manual test. The date is never moved for the user; an unsafe date is rejected.
    static let minimumSchedulingLeadTime: TimeInterval = 5

    let reminderRepository: any ActionItemReminderRepository
    let projectRepository: any ProjectRepository
    let profileRepository: any LocalUserProfileRepository
    let notifications: any LocalNotificationScheduler
    let calendar: Calendar
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        reminderRepository: any ActionItemReminderRepository,
        projectRepository: any ProjectRepository,
        profileRepository: any LocalUserProfileRepository,
        notifications: any LocalNotificationScheduler,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.reminderRepository = reminderRepository
        self.projectRepository = projectRepository
        self.profileRepository = profileRepository
        self.notifications = notifications
        self.calendar = calendar
        self.now = now
        self.makeID = makeID
    }

    static func eligibility(
        of actionItem: ActionItem,
        profile: LocalUserProfile?
    ) -> ActionItemReminderEligibility {
        guard actionItem.status == .confirmed || actionItem.status == .inProgress else {
            return .notConfirmed
        }
        guard MyWorkPolicy.isMine(actionItem, profile: profile) else {
            return .notAssignedToUser
        }
        guard actionItem.dueDate != nil else {
            return .dueDateMissing
        }
        return .eligible
    }

    /// Deterministic suggestion only. The caller must still show it in a DatePicker and pass the
    /// user's confirmed value back to `schedule`.
    func suggestedFireDate(for dueDate: Date) -> Date {
        let reference = now()
        let dueDay = calendar.startOfDay(for: dueDate)
        let dueAtNine = calendar.date(byAdding: .hour, value: 9, to: dueDay) ?? dueDate
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: dueAtNine) ?? dueAtNine
        if dayBefore > reference { return dayBefore }
        if dueAtNine > reference { return dueAtNine }
        return calendar.date(byAdding: .hour, value: 1, to: reference) ?? reference.addingTimeInterval(3600)
    }

    func schedule(projectID: UUID, actionItemID: UUID, fireAt: Date) async throws -> ActionItemReminder {
        let timestamp = now()
        try Self.validate(fireAt: fireAt, relativeTo: timestamp)

        let project: Project
        do {
            guard let loaded = try await projectRepository.project(id: projectID) else {
                throw ActionItemReminderError.projectNotFound
            }
            project = loaded
        } catch let error as ActionItemReminderError {
            throw error
        } catch {
            throw ActionItemReminderError.storageFailure
        }
        guard let actionItem = project.actionItems.first(where: { $0.id == actionItemID }) else {
            throw ActionItemReminderError.actionItemNotFound
        }

        let profile: LocalUserProfile?
        do {
            profile = try await profileRepository.profile()
        } catch {
            throw ActionItemReminderError.storageFailure
        }
        let eligibility = Self.eligibility(of: actionItem, profile: profile)
        guard eligibility == .eligible else {
            throw ActionItemReminderError.ineligible(eligibility)
        }

        switch await notifications.authorizationStatus() {
        case .denied:
            throw ActionItemReminderError.permissionDenied
        case .notDetermined:
            do {
                guard try await notifications.requestAuthorization() else {
                    throw ActionItemReminderError.permissionDenied
                }
            } catch let error as ActionItemReminderError {
                throw error
            } catch {
                throw ActionItemReminderError.notificationFailure
            }
        case .authorized:
            break
        }

        let previous: ActionItemReminder?
        do {
            previous = try await reminderRepository.reminder(for: actionItemID)
        } catch {
            throw ActionItemReminderError.storageFailure
        }
        let reminder = ActionItemReminder(
            id: previous?.id ?? makeID(),
            projectID: projectID,
            actionItemID: actionItemID,
            fireAt: fireAt,
            status: .scheduled,
            createdAt: previous?.createdAt ?? timestamp,
            updatedAt: timestamp,
            cancellationReason: nil
        )
        let request = notificationRequest(for: reminder, actionItem: actionItem, project: project)

        // Permission prompts and storage reads can outlive an imminent selection. Re-check at the
        // OS boundary rather than adding a one-shot calendar trigger whose date is already past.
        // The approved date remains untouched: the user is asked to choose again instead.
        try Self.validate(fireAt: fireAt, relativeTo: now())

        do {
            try await notifications.schedule(request)
        } catch {
            throw ActionItemReminderError.notificationFailure
        }

        do {
            try await reminderRepository.save(reminder)
        } catch {
            // The OS must never claim a new schedule the ledger failed to record. If this was an
            // edit, restore the last recorded request; otherwise remove the unrecorded request.
            await notifications.remove(identifier: reminder.notificationIdentifier)
            if let previous, previous.status == .scheduled,
               let previousProject = try? await projectRepository.project(id: previous.projectID),
               let previousItem = previousProject.actionItems.first(where: { $0.id == previous.actionItemID }) {
                try? await notifications.schedule(
                    notificationRequest(for: previous, actionItem: previousItem, project: previousProject)
                )
            }
            throw ActionItemReminderError.storageFailure
        }
        return reminder
    }

    private static func validate(fireAt: Date, relativeTo reference: Date) throws {
        guard fireAt > reference else {
            throw ActionItemReminderError.fireDateNotInFuture
        }
        guard fireAt.timeIntervalSince(reference) >= minimumSchedulingLeadTime else {
            throw ActionItemReminderError.fireDateTooSoon
        }
    }

    @discardableResult
    func cancel(
        actionItemID: UUID,
        reason: ActionItemReminderCancellationReason = .userCancelled
    ) async throws -> ActionItemReminder? {
        let existing: ActionItemReminder?
        do {
            existing = try await reminderRepository.reminder(for: actionItemID)
        } catch {
            throw ActionItemReminderError.storageFailure
        }
        guard var reminder = existing else { return nil }

        reminder.status = .cancelled
        reminder.updatedAt = now()
        reminder.cancellationReason = reason
        do {
            try await reminderRepository.save(reminder)
        } catch {
            throw ActionItemReminderError.storageFailure
        }
        await notifications.remove(identifier: reminder.notificationIdentifier)
        return reminder
    }

    /// Repairs the local ledger against current projects/profile and the OS pending queue. It never
    /// asks for permission: prompts belong only to an explicit first scheduling action.
    func reconcile() async {
        guard let reminders = try? await reminderRepository.allReminders(),
              let projects = try? await projectRepository.allProjects(),
              let profile = try? await profileRepository.profile() else {
            return
        }
        let pending = await notifications.pendingIdentifiers()
        let permission = await notifications.authorizationStatus()
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        for var reminder in reminders where reminder.status == .scheduled {
            guard let project = projectsByID[reminder.projectID] else {
                _ = try? await cancel(actionItemID: reminder.actionItemID, reason: .projectDeleted)
                continue
            }
            guard let item = project.actionItems.first(where: { $0.id == reminder.actionItemID }) else {
                _ = try? await cancel(actionItemID: reminder.actionItemID, reason: .actionItemDeleted)
                continue
            }

            let eligibility = Self.eligibility(of: item, profile: profile)
            if eligibility != .eligible {
                let reason: ActionItemReminderCancellationReason
                switch eligibility {
                case .notConfirmed:
                    reason = item.status == .completed ? .actionItemCompleted : .actionItemCancelled
                case .notAssignedToUser:
                    reason = .noLongerAssignedToUser
                case .dueDateMissing:
                    reason = .dueDateRemoved
                case .eligible:
                    continue
                }
                _ = try? await cancel(actionItemID: item.id, reason: reason)
                continue
            }

            if reminder.fireAt <= now(), !pending.contains(reminder.notificationIdentifier) {
                reminder.status = .delivered
                reminder.updatedAt = now()
                try? await reminderRepository.save(reminder)
                continue
            }

            guard !pending.contains(reminder.notificationIdentifier) else { continue }
            guard permission == .authorized else {
                _ = try? await cancel(actionItemID: item.id, reason: .notificationPermissionDenied)
                continue
            }
            try? await notifications.schedule(notificationRequest(for: reminder, actionItem: item, project: project))
        }
    }

    private func notificationRequest(
        for reminder: ActionItemReminder,
        actionItem: ActionItem,
        project: Project
    ) -> LocalNotificationRequest {
        LocalNotificationRequest(
            identifier: reminder.notificationIdentifier,
            title: actionItem.title,
            body: "\(project.name) · 마감 업무를 확인할 시간입니다.",
            fireAt: reminder.fireAt
        )
    }
}
