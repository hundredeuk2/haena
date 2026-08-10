import XCTest
@preconcurrency import UserNotifications
@testable import HAENA

final class AgentLedgerReminderIntegrationTests: XCTestCase {
    private static let projectID = UUID(uuidString: "31000000-0000-4000-8000-000000000001")!
    private static let meetingID = UUID(uuidString: "31000000-0000-4000-8000-000000000002")!
    private static let participantID = UUID(uuidString: "31000000-0000-4000-8000-000000000003")!
    private static let actionItemID = UUID(uuidString: "31000000-0000-4000-8000-000000000004")!
    private static let reminderID = UUID(uuidString: "31000000-0000-4000-8000-000000000005")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReminderScheduleSucceedsWhenLedgerWriteFails() async throws {
        let reminders = InMemoryActionItemReminderRepository()
        let notifications = InMemoryLocalNotificationScheduler()
        let service = try await makeService(
            reminders: reminders,
            notifications: notifications,
            ledger: AgentLedgerService(repository: FailingAgentLedgerRepository())
        )

        let reminder = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: Self.now.addingTimeInterval(3_600)
        )

        let storedReminder = await reminders.reminder(for: Self.actionItemID)
        let scheduledRequest = await notifications.scheduledRequest(
            identifier: reminder.notificationIdentifier
        )
        XCTAssertEqual(storedReminder, reminder)
        XCTAssertEqual(
            scheduledRequest?.fireAt,
            reminder.fireAt
        )
        XCTAssertEqual(scheduledRequest?.reminderID, reminder.id)
    }

    func testScheduleRescheduleAndUserCancelRecordDistinctFacts() async throws {
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = try await makeService(
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )
        let firstFire = Self.now.addingTimeInterval(3_600)
        let secondFire = firstFire.addingTimeInterval(600)

        _ = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: firstFire
        )
        _ = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: secondFire
        )
        _ = try await service.cancel(actionItemID: Self.actionItemID)

        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(Set(events.map(\.type)), [.scheduled, .rescheduled, .cancelled])
        let cancellation = try XCTUnwrap(events.first { $0.type == .cancelled }?.cancellation)
        XCTAssertEqual(cancellation.source, .user)
        XCTAssertEqual(cancellation.reason, .userCancelled)
    }

    func testSchedulingAfterUnreconciledPastRunCreatesNewReminderRun() async throws {
        let pastRunID = UUID(uuidString: "31000000-0000-4000-8000-000000000006")!
        let pastReminder = makeReminder(id: pastRunID, fireAt: Self.now.addingTimeInterval(-60))
        let reminders = InMemoryActionItemReminderRepository(reminders: [pastReminder])
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = try await makeService(
            reminders: reminders,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        let newReminder = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: Self.now.addingTimeInterval(3_600)
        )

        XCTAssertEqual(newReminder.id, Self.reminderID)
        XCTAssertNotEqual(newReminder.id, pastRunID)
        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.map(\.type), [.scheduled])
        XCTAssertEqual(events.map(\.reminderID), [Self.reminderID])
    }

    func testRunWhoseFireTimePassesDuringRepositoryReadIsNotReused() async throws {
        let clock = LedgerIntegrationClock(Self.now)
        let pastRunID = UUID(uuidString: "31000000-0000-4000-8000-000000000006")!
        let previous = makeReminder(id: pastRunID, fireAt: Self.now.addingTimeInterval(60))
        let reminders = AdvancingReminderRepository(
            reminder: previous,
            clock: clock,
            readAdvance: 120
        )
        let projects = InMemoryProjectRepository()
        try await projects.save(makeProject(actionItemStatus: .confirmed))
        let profile = LocalUserProfile(
            displayName: "나",
            linkedParticipantIDs: [Self.participantID],
            createdAt: Self.now,
            updatedAt: Self.now
        )
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = ActionItemReminderService(
            reminderRepository: reminders,
            projectRepository: projects,
            profileRepository: InMemoryLocalUserProfileRepository(profile: profile),
            notifications: InMemoryLocalNotificationScheduler(),
            ledger: AgentLedgerService(repository: ledgerRepository, now: { clock.now() }),
            now: { clock.now() },
            makeID: { Self.reminderID }
        )

        let scheduled = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: Self.now.addingTimeInterval(3_600)
        )

        XCTAssertEqual(scheduled.id, Self.reminderID)
        XCTAssertNotEqual(scheduled.id, pastRunID)
        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.map(\.type), [.scheduled])
    }

    func testDuplicateReconcileRecordsFireTimeReachedOnce() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(-60))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = try await makeService(
            reminders: reminders,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        await service.reconcile()
        await service.reconcile()

        let events = await ledgerRepository.events(limit: nil)
        let storedReminder = await reminders.reminder(for: Self.actionItemID)
        XCTAssertEqual(events.filter { $0.type == .fireTimeReached }.count, 1)
        XCTAssertEqual(storedReminder?.status, .delivered)
    }

    func testCompletionRecordsRelationshipAndPolicyCancellationOnce() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(-60))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let notifications = InMemoryLocalNotificationScheduler(
            requests: [notificationRequest(for: reminder)]
        )
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = try await makeService(
            actionItemStatus: .completed,
            reminders: reminders,
            notifications: notifications,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        await service.reconcile()
        await service.reconcile()

        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.filter { $0.type == .taskCompletedAfterReminder }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .cancelled }.count, 1)
        XCTAssertEqual(
            events.first { $0.type == .cancelled }?.cancellation,
            AgentLedgerCancellation(source: .policy, reason: .actionItemCompleted)
        )
    }

    func testCompletionBeforeFutureReminderRecordsOnlyPolicyCancellation() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(3_600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let notifications = InMemoryLocalNotificationScheduler(
            requests: [notificationRequest(for: reminder)]
        )
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let service = try await makeService(
            actionItemStatus: .completed,
            reminders: reminders,
            notifications: notifications,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        await service.reconcile()

        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.filter { $0.type == .taskCompletedAfterReminder }.count, 0)
        XCTAssertEqual(events.filter { $0.type == .fireTimeReached }.count, 0)
        XCTAssertEqual(events.filter { $0.type == .cancelled }.count, 1)
    }

    func testClearThenReconcileDoesNotRestorePastScheduledOrDeliveredDerivedFacts() async throws {
        let scheduledReminder = makeReminder(fireAt: Self.now.addingTimeInterval(-60))
        let scheduledRepository = InMemoryActionItemReminderRepository(reminders: [scheduledReminder])
        let scheduledLedger = InMemoryAgentLedgerRepository()
        let scheduledLedgerService = AgentLedgerService(repository: scheduledLedger, now: { Self.now })
        let scheduledService = try await makeService(
            reminders: scheduledRepository,
            ledger: scheduledLedgerService
        )
        try await scheduledLedgerService.clearAll()

        await scheduledService.reconcile()
        let scheduledEvents = await scheduledLedger.events(limit: nil)
        XCTAssertTrue(scheduledEvents.isEmpty)

        let deliveredReminder = makeReminder(
            fireAt: Self.now.addingTimeInterval(-3_600),
            status: .delivered
        )
        let deliveredRepository = InMemoryActionItemReminderRepository(reminders: [deliveredReminder])
        let deliveredLedger = InMemoryAgentLedgerRepository()
        let deliveredLedgerService = AgentLedgerService(repository: deliveredLedger, now: { Self.now })
        let deliveredService = try await makeService(
            actionItemStatus: .completed,
            reminders: deliveredRepository,
            ledger: deliveredLedgerService
        )
        try await deliveredLedgerService.clearAll()

        await deliveredService.reconcile()
        let deliveredEvents = await deliveredLedger.events(limit: nil)
        XCTAssertTrue(deliveredEvents.isEmpty)
    }

    func testFutureReminderExistingAtClearCanRecordWhenItsFireTimeLaterPasses() async throws {
        let clock = LedgerIntegrationClock(Self.now)
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(120))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let ledger = AgentLedgerService(repository: ledgerRepository, now: { clock.now() })
        let service = try await makeService(
            reminders: reminders,
            ledger: ledger,
            now: { clock.now() }
        )
        try await ledger.clearAll()
        clock.advance(by: 180)

        await service.reconcile()

        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.map(\.type), [.fireTimeReached])
        XCTAssertEqual(events.map(\.reminderID), [reminder.id])
    }

    func testNotificationBridgeRecordsOnlySafelyResolvedCallbacksAndDeduplicates() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(3_600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let bridge = AgentNotificationLedgerBridge(
            reminderRepository: reminders,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        await bridge.record(
            .presentedForeground(identifier: reminder.notificationIdentifier, reminderID: reminder.id)
        )
        await bridge.record(
            .presentedForeground(identifier: reminder.notificationIdentifier, reminderID: reminder.id)
        )
        await bridge.record(
            .openedFromNotification(identifier: reminder.notificationIdentifier, reminderID: reminder.id)
        )
        await bridge.record(.openedFromNotification(identifier: "another-app.notification", reminderID: reminder.id))
        await bridge.record(
            .openedFromNotification(identifier: "haena.action-item-reminder.not-a-uuid", reminderID: reminder.id)
        )
        await bridge.record(
            .openedFromNotification(identifier: reminder.notificationIdentifier, reminderID: nil)
        )

        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.filter { $0.type == .presentedForeground }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .openedFromNotification }.count, 1)
        XCTAssertEqual(Set(events.map(\.reminderID)), [reminder.id])
    }

    func testOldNotificationCallbackIsNotAttributedToNewReminderRunForSameTask() async throws {
        let previousRunID = UUID(uuidString: "31000000-0000-4000-8000-000000000006")!
        let currentReminder = makeReminder(fireAt: Self.now.addingTimeInterval(3_600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [currentReminder])
        let ledgerRepository = InMemoryAgentLedgerRepository()
        let bridge = AgentNotificationLedgerBridge(
            reminderRepository: reminders,
            ledger: AgentLedgerService(repository: ledgerRepository, now: { Self.now })
        )

        // Identifier is intentionally the same because the OS request is keyed by ActionItem.
        await bridge.record(
            .openedFromNotification(
                identifier: currentReminder.notificationIdentifier,
                reminderID: previousRunID
            )
        )
        let eventsAfterOldCallback = await ledgerRepository.events(limit: nil)
        XCTAssertTrue(eventsAfterOldCallback.isEmpty)

        await bridge.record(
            .openedFromNotification(
                identifier: currentReminder.notificationIdentifier,
                reminderID: currentReminder.id
            )
        )
        let events = await ledgerRepository.events(limit: nil)
        XCTAssertEqual(events.map(\.reminderID), [currentReminder.id])
    }

    func testNotificationDelegateCompletesEachPathExactlyOnceBeforeObserving() {
        let probe = NotificationLifecycleProbe()
        let delegate = ForegroundNotificationDelegate { callback in probe.observe(callback) }
        var presentationCompletions = 0
        var responseCompletions = 0

        delegate.handleWillPresent(identifier: "foreground", reminderID: Self.reminderID) { options in
            presentationCompletions += 1
            XCTAssertEqual(options, ForegroundNotificationDelegate.presentationOptions)
            XCTAssertTrue(probe.callbacks.isEmpty, "OS completion must not wait for ledger observation.")
        }
        delegate.handleResponse(identifier: "opened", reminderID: Self.reminderID) {
            responseCompletions += 1
            XCTAssertEqual(probe.callbacks.count, 1)
        }

        XCTAssertEqual(presentationCompletions, 1)
        XCTAssertEqual(responseCompletions, 1)
        XCTAssertEqual(
            probe.callbacks,
            [
                .presentedForeground(identifier: "foreground", reminderID: Self.reminderID),
                .openedFromNotification(identifier: "opened", reminderID: Self.reminderID)
            ]
        )
    }

    func testNotificationIdentifierParserRejectsExtraOrForeignComponents() {
        XCTAssertEqual(
            AgentNotificationLedgerBridge.actionItemID(
                from: ActionItemReminder.notificationIdentifier(for: Self.actionItemID)
            ),
            Self.actionItemID
        )
        XCTAssertNil(AgentNotificationLedgerBridge.actionItemID(from: "foreign.\(Self.actionItemID)"))
        XCTAssertNil(
            AgentNotificationLedgerBridge.actionItemID(
                from: "haena.action-item-reminder.\(Self.actionItemID.uuidString).extra"
            )
        )
    }

    private func makeService(
        actionItemStatus: ActionItemStatus = .confirmed,
        reminders: any ActionItemReminderRepository = InMemoryActionItemReminderRepository(),
        notifications: any LocalNotificationScheduler = InMemoryLocalNotificationScheduler(),
        ledger: AgentLedgerService? = nil,
        now: @escaping @Sendable () -> Date = { AgentLedgerReminderIntegrationTests.now }
    ) async throws -> ActionItemReminderService {
        let projects = InMemoryProjectRepository()
        try await projects.save(makeProject(actionItemStatus: actionItemStatus))
        let profile = LocalUserProfile(
            displayName: "나",
            linkedParticipantIDs: [Self.participantID],
            createdAt: Self.now,
            updatedAt: Self.now
        )
        return ActionItemReminderService(
            reminderRepository: reminders,
            projectRepository: projects,
            profileRepository: InMemoryLocalUserProfileRepository(profile: profile),
            notifications: notifications,
            ledger: ledger,
            now: now,
            makeID: { Self.reminderID }
        )
    }

    private func makeProject(actionItemStatus: ActionItemStatus) -> Project {
        let participant = Participant(
            id: Self.participantID,
            displayName: "나",
            linkedUserID: nil,
            speakerLabel: "A"
        )
        let meeting = Meeting(
            id: Self.meetingID,
            projectID: Self.projectID,
            title: "검증 회의",
            occurredAt: Self.now,
            sourceType: .pastedText,
            participants: [participant],
            transcriptSegments: [],
            createdAt: Self.now
        )
        let item = ActionItem(
            id: Self.actionItemID,
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            title: "Private 반복 검증",
            details: nil,
            assigneeID: Self.participantID,
            dueDate: Self.now.addingTimeInterval(86_400),
            status: actionItemStatus,
            evidence: nil,
            confidence: .maximum,
            createdAt: Self.now,
            updatedAt: Self.now
        )
        return Project(
            id: Self.projectID,
            name: "Agent Ledger",
            summary: "",
            createdAt: Self.now,
            updatedAt: Self.now,
            meetings: [meeting],
            decisions: [],
            actionItems: [item],
            openQuestions: [],
            nextAgenda: []
        )
    }

    private func makeReminder(
        id: UUID = AgentLedgerReminderIntegrationTests.reminderID,
        fireAt: Date,
        status: ActionItemReminderStatus = .scheduled
    ) -> ActionItemReminder {
        ActionItemReminder(
            id: id,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: fireAt,
            status: status,
            createdAt: Self.now,
            updatedAt: Self.now,
            cancellationReason: nil
        )
    }

    private func notificationRequest(for reminder: ActionItemReminder) -> LocalNotificationRequest {
        LocalNotificationRequest(
            identifier: reminder.notificationIdentifier,
            title: "Private 반복 검증",
            body: "Agent Ledger",
            fireAt: reminder.fireAt,
            reminderID: reminder.id
        )
    }
}

private final class NotificationLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LocalNotificationLifecycleCallback] = []

    var callbacks: [LocalNotificationLifecycleCallback] {
        lock.withLock { stored }
    }

    func observe(_ callback: LocalNotificationLifecycleCallback) {
        lock.withLock { stored.append(callback) }
    }
}

private final class LedgerIntegrationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor AdvancingReminderRepository: ActionItemReminderRepository {
    private var stored: ActionItemReminder?
    private let clock: LedgerIntegrationClock
    private let readAdvance: TimeInterval
    private var didAdvance = false

    init(
        reminder: ActionItemReminder,
        clock: LedgerIntegrationClock,
        readAdvance: TimeInterval
    ) {
        stored = reminder
        self.clock = clock
        self.readAdvance = readAdvance
    }

    func reminder(for actionItemID: UUID) -> ActionItemReminder? {
        if !didAdvance {
            clock.advance(by: readAdvance)
            didAdvance = true
        }
        return stored?.actionItemID == actionItemID ? stored : nil
    }

    func allReminders() -> [ActionItemReminder] {
        stored.map { [$0] } ?? []
    }

    func save(_ reminder: ActionItemReminder) {
        stored = reminder
    }
}
