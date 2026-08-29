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
    /// Observation-only sidecar. Its failures are swallowed by `AgentLedgerService`, so the
    /// reminder transaction above it keeps the same success and rollback guarantees.
    let ledger: AgentLedgerService?
    let calendar: Calendar
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        reminderRepository: any ActionItemReminderRepository,
        projectRepository: any ProjectRepository,
        profileRepository: any LocalUserProfileRepository,
        notifications: any LocalNotificationScheduler,
        ledger: AgentLedgerService? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.reminderRepository = reminderRepository
        self.projectRepository = projectRepository
        self.profileRepository = profileRepository
        self.notifications = notifications
        self.ledger = ledger
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
        // Permission and repository work above can take long enough for an old run to fire. Use a
        // fresh boundary after reading it; the function-entry timestamp is no longer truthful.
        let runBoundaryTime = now()
        let activePrevious = previous.flatMap {
            $0.status == .scheduled && $0.fireAt > runBoundaryTime ? $0 : nil
        }
        let isReschedule = activePrevious != nil
        let reminder = ActionItemReminder(
            // A schedule after a delivered/cancelled reminder is a new run. Keeping an id only
            // while editing an active schedule makes one feedback choice mean one reminder run.
            id: activePrevious?.id ?? makeID(),
            projectID: projectID,
            actionItemID: actionItemID,
            fireAt: fireAt,
            // Recorded at the moment of approval, so a later reconcile can tell that the deadline
            // moved rather than having to infer it from the fire time.
            approvedDueDate: actionItem.dueDate,
            status: .scheduled,
            createdAt: activePrevious?.createdAt ?? timestamp,
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
        if isReschedule {
            await ledger?.recordRescheduled(
                reminderID: reminder.id,
                projectID: reminder.projectID,
                actionItemID: reminder.actionItemID,
                scheduledFor: reminder.fireAt
            )
        } else {
            await ledger?.recordScheduled(
                reminderID: reminder.id,
                projectID: reminder.projectID,
                actionItemID: reminder.actionItemID,
                scheduledFor: reminder.fireAt
            )
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
        await ledger?.recordCancelled(
            reminderID: reminder.id,
            projectID: reminder.projectID,
            actionItemID: reminder.actionItemID,
            scheduledFor: reminder.fireAt,
            reason: reason
        )
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
        let reconciliationTime = now()

        for var reminder in reminders where reminder.status == .scheduled || reminder.status == .delivered {
            // This says only what reconcile can prove from its clock: the approved fire time is in
            // the past. It does not infer OS delivery or user attention, and it remains recordable
            // even if the related project/task was deleted after scheduling.
            let fireTimeWasReached = reminder.status == .delivered || reminder.fireAt <= reconciliationTime
            if reminder.fireAt <= reconciliationTime {
                await ledger?.recordFireTimeReached(
                    reminderID: reminder.id,
                    projectID: reminder.projectID,
                    actionItemID: reminder.actionItemID,
                    scheduledFor: reminder.fireAt
                )
            }

            guard let project = projectsByID[reminder.projectID] else {
                if reminder.status == .scheduled {
                    _ = try? await cancel(actionItemID: reminder.actionItemID, reason: .projectDeleted)
                }
                continue
            }
            guard let item = project.actionItems.first(where: { $0.id == reminder.actionItemID }) else {
                if reminder.status == .scheduled {
                    _ = try? await cancel(actionItemID: reminder.actionItemID, reason: .actionItemDeleted)
                }
                continue
            }

            if item.status == .completed {
                // A completion before a future reminder is not evidence that the reminder helped
                // recover the task. Keep the cancellation fact, but only add this relationship
                // once the approved fire time has passed (or the job was already reconciled).
                if fireTimeWasReached {
                    await ledger?.recordTaskCompletedAfterReminder(
                        reminderID: reminder.id,
                        projectID: reminder.projectID,
                        actionItemID: reminder.actionItemID,
                        scheduledFor: reminder.fireAt
                    )
                }
                if reminder.status == .scheduled {
                    _ = try? await cancel(actionItemID: item.id, reason: .actionItemCompleted)
                }
                continue
            }

            // A delivered reminder has no OS request left to repair. It remains useful as the
            // relationship anchor for a later task-completion fact above.
            guard reminder.status == .scheduled else { continue }

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

            // The deadline moved after the user approved a time for it. Following it automatically
            // would rewrite a time the user chose, so the job is retired and they are asked to
            // approve a new one. A nil `approvedDueDate` is a row written before this was recorded:
            // unknown, not mismatched, so it is left alone rather than cancelled on a guess.
            if let approvedDueDate = reminder.approvedDueDate, item.dueDate != approvedDueDate {
                _ = try? await cancel(actionItemID: item.id, reason: .dueDateChanged)
                continue
            }

            if reminder.fireAt <= reconciliationTime, !pending.contains(reminder.notificationIdentifier) {
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
            fireAt: reminder.fireAt,
            reminderID: reminder.id
        )
    }
}
