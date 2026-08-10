import XCTest
@preconcurrency import UserNotifications
@testable import HAENA

final class ActionItemReminderTests: XCTestCase {
    private static let projectID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let meetingID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let participantID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    private static let actionItemID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
    private static let reminderID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var directory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Reminder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    func testEligibilityRequiresAnActiveConfirmedTaskOwnedByTheLocalUserWithADueDate() {
        let profile = makeProfile()
        XCTAssertEqual(
            ActionItemReminderService.eligibility(of: makeActionItem(), profile: profile),
            .eligible
        )
        XCTAssertEqual(
            ActionItemReminderService.eligibility(of: makeActionItem(status: .proposed), profile: profile),
            .notConfirmed
        )
        XCTAssertEqual(
            ActionItemReminderService.eligibility(of: makeActionItem(assigneeID: UUID()), profile: profile),
            .notAssignedToUser
        )
        XCTAssertEqual(
            ActionItemReminderService.eligibility(of: makeActionItem(dueDate: nil), profile: profile),
            .dueDateMissing
        )
    }

    func testSuggestedTimeUsesDayBeforeNineThenDueDayNineThenOneHourFromNow() async throws {
        let service = try await makeService()
        let due = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Self.now))!
        let dayBeforeNine = calendar.date(byAdding: .hour, value: 9, to: calendar.date(byAdding: .day, value: -1, to: due)!)!
        XCTAssertEqual(service.suggestedFireDate(for: due), dayBeforeNine)

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Self.now))!
        let tomorrowNine = calendar.date(byAdding: .hour, value: 9, to: tomorrow)!
        let afterDayBefore = tomorrow.addingTimeInterval(60)
        let dueDayService = try await makeService(now: { afterDayBefore })
        XCTAssertEqual(dueDayService.suggestedFireDate(for: tomorrow), tomorrowNine)

        let afterDueDayNine = tomorrowNine.addingTimeInterval(60)
        let pastDueService = try await makeService(now: { afterDueDayNine })
        XCTAssertEqual(
            pastDueService.suggestedFireDate(for: tomorrow),
            tomorrowNine.addingTimeInterval(3660)
        )
    }

    func testFirstScheduleRequestsPermissionThenStoresExactlyOneJobAndOSRequest() async throws {
        let notifications = InMemoryLocalNotificationScheduler(authorization: .notDetermined)
        let reminders = InMemoryActionItemReminderRepository()
        let service = try await makeService(reminders: reminders, notifications: notifications)
        let fireAt = Self.now.addingTimeInterval(7200)

        let first = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: fireAt
        )
        let changed = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: fireAt.addingTimeInterval(600)
        )

        let authorization = await notifications.authorizationStatus()
        let allReminders = await reminders.allReminders()
        let stored = await reminders.reminder(for: Self.actionItemID)
        let scheduledRequest = await notifications.scheduledRequest(identifier: changed.notificationIdentifier)
        XCTAssertEqual(authorization, .authorized)
        XCTAssertEqual(first.id, changed.id)
        XCTAssertEqual(allReminders.count, 1)
        XCTAssertEqual(stored?.fireAt, changed.fireAt)
        XCTAssertEqual(scheduledRequest?.fireAt, changed.fireAt)
    }

    func testMinuteAheadScheduleIsAcceptedWithoutChangingApprovedFireDate() async throws {
        let notifications = InMemoryLocalNotificationScheduler()
        let reminders = InMemoryActionItemReminderRepository()
        let service = try await makeService(reminders: reminders, notifications: notifications)
        let approvedFireAt = Self.now.addingTimeInterval(60)

        let reminder = try await service.schedule(
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: approvedFireAt
        )

        let request = await notifications.scheduledRequest(identifier: reminder.notificationIdentifier)
        XCTAssertEqual(reminder.fireAt, approvedFireAt)
        XCTAssertEqual(request?.fireAt, approvedFireAt)
    }

    func testScheduleRechecksImminentDateAfterAuthorizationWithoutCreatingAJob() async throws {
        let clock = MutableReminderClock(Self.now)
        let notifications = AdvancingAuthorizationNotificationScheduler(
            clock: clock,
            authorizationDelay: 58
        )
        let reminders = InMemoryActionItemReminderRepository()
        let service = try await makeService(
            reminders: reminders,
            notifications: notifications,
            now: { clock.now() }
        )

        do {
            _ = try await service.schedule(
                projectID: Self.projectID,
                actionItemID: Self.actionItemID,
                fireAt: Self.now.addingTimeInterval(60)
            )
            XCTFail("Expected a date made imminent by authorization to be rejected.")
        } catch let error as ActionItemReminderError {
            XCTAssertEqual(error, .fireDateTooSoon)
        }

        let storedReminders = await reminders.allReminders()
        let pendingIdentifiers = await notifications.pendingIdentifiers()
        XCTAssertTrue(storedReminders.isEmpty)
        XCTAssertTrue(pendingIdentifiers.isEmpty)
    }

    func testRejectedImminentChangeKeepsExistingApprovedFireDate() async throws {
        let existing = makeReminder(fireAt: Self.now.addingTimeInterval(3600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [existing])
        let notifications = InMemoryLocalNotificationScheduler(
            requests: [makeNotificationRequest(for: existing)]
        )
        let service = try await makeService(reminders: reminders, notifications: notifications)

        do {
            _ = try await service.schedule(
                projectID: Self.projectID,
                actionItemID: Self.actionItemID,
                fireAt: Self.now.addingTimeInterval(2)
            )
            XCTFail("Expected an imminent change to be rejected.")
        } catch let error as ActionItemReminderError {
            XCTAssertEqual(error, .fireDateTooSoon)
        }

        let stored = await reminders.reminder(for: Self.actionItemID)
        let pending = await notifications.scheduledRequest(identifier: existing.notificationIdentifier)
        XCTAssertEqual(stored?.fireAt, existing.fireAt)
        XCTAssertEqual(pending?.fireAt, existing.fireAt)
    }

    func testForegroundNotificationContractRequestsBannerListAndSound() {
        let options = ForegroundNotificationDelegate.presentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertTrue(options.contains(.sound))
    }

    func testUserNotificationSchedulerRetainsItsWeaklyInstalledDelegate() {
        let center = UNUserNotificationCenter.current()
        let originalDelegate = center.delegate
        defer { center.delegate = originalDelegate }

        var scheduler: UserNotificationScheduler? = UserNotificationScheduler(center: center)
        weak var installedDelegate: ForegroundNotificationDelegate?
        installedDelegate = scheduler?.foregroundDelegate

        XCTAssertNotNil(installedDelegate)
        XCTAssertTrue(center.delegate === installedDelegate)

        scheduler = nil
        XCTAssertNil(installedDelegate, "The center is weak; scheduler ownership must define the delegate lifetime.")
    }

    func testDeniedPermissionDoesNotCreateAJob() async throws {
        let notifications = InMemoryLocalNotificationScheduler(authorization: .denied)
        let reminders = InMemoryActionItemReminderRepository()
        let service = try await makeService(reminders: reminders, notifications: notifications)

        do {
            _ = try await service.schedule(
                projectID: Self.projectID,
                actionItemID: Self.actionItemID,
                fireAt: Self.now.addingTimeInterval(3600)
            )
            XCTFail("Expected denied permission to fail.")
        } catch let error as ActionItemReminderError {
            XCTAssertEqual(error, .permissionDenied)
        }
        let stored = await reminders.allReminders()
        XCTAssertTrue(stored.isEmpty)
    }

    func testStorageFailureRollsBackTheOSRequest() async throws {
        let reminders = InMemoryActionItemReminderRepository(saveError: CocoaError(.fileWriteUnknown))
        let notifications = InMemoryLocalNotificationScheduler()
        let service = try await makeService(reminders: reminders, notifications: notifications)

        do {
            _ = try await service.schedule(
                projectID: Self.projectID,
                actionItemID: Self.actionItemID,
                fireAt: Self.now.addingTimeInterval(3600)
            )
            XCTFail("Expected storage failure.")
        } catch let error as ActionItemReminderError {
            XCTAssertEqual(error, .storageFailure)
        }
        let pending = await notifications.pendingIdentifiers()
        XCTAssertTrue(pending.isEmpty)
    }

    func testJSONStoreSurvivesReloadAndUpsertsByActionItem() async throws {
        let url = directory.appendingPathComponent("agent-jobs.json")
        let firstStore = JSONActionItemReminderRepository(fileURL: url)
        let first = makeReminder(fireAt: Self.now.addingTimeInterval(3600))
        var changed = first
        changed.fireAt = Self.now.addingTimeInterval(7200)
        changed.updatedAt = Self.now.addingTimeInterval(60)
        try await firstStore.save(first)
        try await firstStore.save(changed)

        let reloaded = JSONActionItemReminderRepository(fileURL: url)
        let loaded = try await reloaded.allReminders()
        XCTAssertEqual(loaded, [changed])
        let raw = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(raw.contains("\"schemaVersion\":1"))
    }

    func testReconcileCancelsACompletedTaskAndRecordsWhy() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(3600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let notifications = InMemoryLocalNotificationScheduler(
            requests: [makeNotificationRequest(for: reminder)]
        )
        let service = try await makeService(
            actionItem: makeActionItem(status: .completed),
            reminders: reminders,
            notifications: notifications
        )

        await service.reconcile()

        let stored = await reminders.reminder(for: Self.actionItemID)
        XCTAssertEqual(stored?.status, .cancelled)
        XCTAssertEqual(stored?.cancellationReason, .actionItemCompleted)
        let pending = await notifications.pendingIdentifiers()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReconcileRestoresAMissingPendingRequestWithoutPrompting() async throws {
        let reminder = makeReminder(fireAt: Self.now.addingTimeInterval(3600))
        let reminders = InMemoryActionItemReminderRepository(reminders: [reminder])
        let notifications = InMemoryLocalNotificationScheduler(authorization: .authorized)
        let service = try await makeService(reminders: reminders, notifications: notifications)

        await service.reconcile()

        let pending = await notifications.pendingIdentifiers()
        let stored = await reminders.reminder(for: Self.actionItemID)
        XCTAssertEqual(pending, [reminder.notificationIdentifier])
        XCTAssertEqual(stored?.status, .scheduled)
    }

    private func makeService(
        actionItem: ActionItem? = nil,
        reminders: any ActionItemReminderRepository = InMemoryActionItemReminderRepository(),
        notifications: any LocalNotificationScheduler = InMemoryLocalNotificationScheduler(),
        now: @escaping @Sendable () -> Date = { ActionItemReminderTests.now }
    ) async throws -> ActionItemReminderService {
        let projects = InMemoryProjectRepository()
        try await projects.save(makeProject(actionItem: actionItem ?? makeActionItem()))
        let profiles = InMemoryLocalUserProfileRepository(profile: makeProfile())
        return ActionItemReminderService(
            reminderRepository: reminders,
            projectRepository: projects,
            profileRepository: profiles,
            notifications: notifications,
            calendar: calendar,
            now: now,
            makeID: { Self.reminderID }
        )
    }

    private func makeProfile() -> LocalUserProfile {
        LocalUserProfile(
            displayName: "나",
            linkedParticipantIDs: [Self.participantID],
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    private func makeActionItem(
        status: ActionItemStatus = .confirmed,
        assigneeID: UUID? = ActionItemReminderTests.participantID,
        dueDate: Date? = ActionItemReminderTests.now.addingTimeInterval(86_400)
    ) -> ActionItem {
        ActionItem(
            id: Self.actionItemID,
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            title: "기획안 정리",
            details: nil,
            assigneeID: assigneeID,
            dueDate: dueDate,
            status: status,
            evidence: nil,
            confidence: Confidence(0.9),
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    private func makeProject(actionItem: ActionItem) -> Project {
        let participant = Participant(
            id: Self.participantID,
            displayName: "나",
            linkedUserID: nil,
            speakerLabel: "A"
        )
        let meeting = Meeting(
            id: Self.meetingID,
            projectID: Self.projectID,
            title: "주간 회의",
            occurredAt: Self.now,
            sourceType: .pastedText,
            participants: [participant],
            transcriptSegments: [],
            createdAt: Self.now
        )
        return Project(
            id: Self.projectID,
            name: "출시 준비",
            summary: "",
            createdAt: Self.now,
            updatedAt: Self.now,
            meetings: [meeting],
            decisions: [],
            actionItems: [actionItem],
            openQuestions: [],
            nextAgenda: []
        )
    }

    private func makeReminder(fireAt: Date) -> ActionItemReminder {
        ActionItemReminder(
            id: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            fireAt: fireAt,
            status: .scheduled,
            createdAt: Self.now,
            updatedAt: Self.now,
            cancellationReason: nil
        )
    }

    private func makeNotificationRequest(for reminder: ActionItemReminder) -> LocalNotificationRequest {
        LocalNotificationRequest(
            identifier: reminder.notificationIdentifier,
            title: "기획안 정리",
            body: "출시 준비",
            fireAt: reminder.fireAt
        )
    }
}

private final class MutableReminderClock: @unchecked Sendable {
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

private actor AdvancingAuthorizationNotificationScheduler: LocalNotificationScheduler {
    private let clock: MutableReminderClock
    private let authorizationDelay: TimeInterval
    private var authorization: LocalNotificationAuthorization = .notDetermined
    private var requests: [String: LocalNotificationRequest] = [:]

    init(clock: MutableReminderClock, authorizationDelay: TimeInterval) {
        self.clock = clock
        self.authorizationDelay = authorizationDelay
    }

    func authorizationStatus() -> LocalNotificationAuthorization { authorization }

    func requestAuthorization() -> Bool {
        clock.advance(by: authorizationDelay)
        authorization = .authorized
        return true
    }

    func schedule(_ request: LocalNotificationRequest) {
        requests[request.identifier] = request
    }

    func remove(identifier: String) {
        requests.removeValue(forKey: identifier)
    }

    func pendingIdentifiers() -> Set<String> {
        Set(requests.keys)
    }
}
