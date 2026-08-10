import XCTest
@testable import HAENA

final class AgentLedgerTests: XCTestCase {
    private static let reminderID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
    private static let projectID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
    private static let actionItemID = UUID(uuidString: "21000000-0000-0000-0000-000000000003")!
    private static let eventID = UUID(uuidString: "21000000-0000-0000-0000-000000000004")!
    private static let secondEventID = UUID(uuidString: "21000000-0000-0000-0000-000000000005")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let fireAt = now.addingTimeInterval(3_600)

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-AgentLedger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    func testDomainEncodingContainsOnlyWhitelistedEvidenceAndNoPrivateContentFields() throws {
        let event = makeEvent(
            type: .cancelled,
            cancellation: AgentLedgerCancellation(source: .policy, reason: .actionItemCompleted)
        )

        let data = try JSONEncoder().encode(AgentLedgerStoreFile(events: [event]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertTrue(json.contains("\"deduplicationKey\""))
        for forbidden in [
            "projectName", "actionItemTitle", "meetingTitle", "transcript", "notificationTitle",
            "notificationBody", "participantName", "assigneeName", "evidence", "quote", "taskTitle",
            "apiKey", "freeText", "modelOutput"
        ] {
            XCTAssertFalse(json.contains(forbidden), "Ledger JSON must not contain \(forbidden).")
        }
    }

    func testAppendIsIdempotentByDeduplicationKey() async throws {
        let repository = InMemoryAgentLedgerRepository()
        let first = makeEvent(id: Self.eventID)
        let retry = makeEvent(id: Self.secondEventID, occurredAt: Self.now.addingTimeInterval(10))

        let storedFirst = await repository.append(first)
        let storedRetry = await repository.append(retry)
        let events = await repository.events(limit: nil)

        XCTAssertEqual(storedFirst, first)
        XCTAssertEqual(storedRetry, first)
        XCTAssertEqual(events, [first])
    }

    func testEventsAreNewestFirstAndLimitIsApplied() async throws {
        let older = makeEvent(id: Self.eventID, occurredAt: Self.now)
        let newer = makeEvent(
            id: Self.secondEventID,
            type: .fireTimeReached,
            occurredAt: Self.now.addingTimeInterval(60),
            deduplicationKey: "fire-newer"
        )
        let repository = InMemoryAgentLedgerRepository(events: [older, newer])

        let all = await repository.events(limit: nil)
        let one = await repository.events(limit: 1)
        let none = await repository.events(limit: 0)
        XCTAssertEqual(all, [newer, older])
        XCTAssertEqual(one, [newer])
        XCTAssertEqual(none, [])
    }

    func testJSONRepositorySurvivesReloadUsesVersionedEnvelopeAndRestrictsPermissions() async throws {
        let url = directory.appendingPathComponent("agent-ledger.json")
        let firstRepository = JSONAgentLedgerRepository(fileURL: url)
        let event = makeEvent()
        try await firstRepository.append(event)

        let reloaded = JSONAgentLedgerRepository(fileURL: url)
        let reloadedEvents = try await reloaded.events(limit: nil)
        XCTAssertEqual(reloadedEvents, [event])

        let data = try Data(contentsOf: url)
        let store = try JSONDecoder().decode(AgentLedgerStoreFile.self, from: data)
        XCTAssertEqual(store.schemaVersion, 1)
        XCTAssertEqual(store.events, [event])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testJSONRepositoryRejectsUnsupportedSchema() async throws {
        let url = directory.appendingPathComponent("agent-ledger.json")
        let data = try JSONEncoder().encode(AgentLedgerStoreFile(schemaVersion: 99, events: []))
        try data.write(to: url)
        let repository = JSONAgentLedgerRepository(fileURL: url)

        do {
            _ = try await repository.events(limit: nil)
            XCTFail("Expected unsupported schema to fail.")
        } catch let error as JSONRepositoryError {
            guard case .unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, 1)
        }
    }

    func testFeedbackUpsertKeepsOneEventAndPreservesItsIdentityAndDedupKey() async throws {
        let repository = InMemoryAgentLedgerRepository(events: [makeEvent()])
        let firstService = AgentLedgerService(
            repository: repository,
            now: { Self.now },
            makeID: { Self.eventID }
        )
        let source = makeEvent()
        let first = try await firstService.setFeedback(.helpful, for: source)
        let secondService = AgentLedgerService(
            repository: repository,
            now: { Self.now.addingTimeInterval(60) },
            makeID: { Self.secondEventID }
        )
        let updated = try await secondService.setFeedback(.tooLate, for: source)
        let events = await repository.events(limit: nil)
        let feedbackEvents = events.filter { $0.type == .feedback }

        XCTAssertEqual(feedbackEvents.count, 1)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.deduplicationKey, first.deduplicationKey)
        XCTAssertEqual(updated.feedback, .tooLate)
        XCTAssertEqual(updated.occurredAt, Self.now.addingTimeInterval(60))
    }

    func testClearFeedbackOnlyRemovesFeedbackForRequestedReminder() async throws {
        let otherReminderID = UUID(uuidString: "21000000-0000-0000-0000-000000000099")!
        let source = makeEvent()
        let ownFeedback = makeEvent(
            id: Self.secondEventID,
            type: .feedback,
            deduplicationKey: "feedback-own",
            feedback: .helpful
        )
        let otherFeedback = AgentLedgerEvent(
            id: UUID(),
            deduplicationKey: "feedback-other",
            reminderID: otherReminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            type: .feedback,
            occurredAt: Self.now,
            feedback: .tooEarly
        )
        let repository = InMemoryAgentLedgerRepository(events: [source, ownFeedback, otherFeedback])

        await repository.clearFeedback(for: Self.reminderID)
        let events = await repository.events(limit: nil)

        XCTAssertTrue(events.contains(source))
        XCTAssertFalse(events.contains(ownFeedback))
        XCTAssertTrue(events.contains(otherFeedback))
    }

    func testClearAllPersistsAnEmptyVersionedStore() async throws {
        let url = directory.appendingPathComponent("agent-ledger.json")
        let repository = JSONAgentLedgerRepository(fileURL: url)
        try await repository.append(makeEvent())
        let service = AgentLedgerService(repository: repository, now: { Self.now })

        try await service.clearAll()

        let events = try await service.events()
        XCTAssertEqual(events, [])
        let store = try JSONDecoder().decode(AgentLedgerStoreFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(store, AgentLedgerStoreFile(clearedAt: Self.now))
    }

    func testClearWatermarkSuppressesOldDerivedFactsButAllowsFutureFireAndNewCallback() async throws {
        let repository = InMemoryAgentLedgerRepository(events: [makeEvent()])
        let service = AgentLedgerService(repository: repository, now: { Self.now })
        try await service.clearAll()

        await service.recordFireTimeReached(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.now.addingTimeInterval(-60)
        )
        await service.recordTaskCompletedAfterReminder(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.now.addingTimeInterval(-60)
        )
        let eventsAfterOldDerivedFacts = await repository.events(limit: nil)
        XCTAssertTrue(eventsAfterOldDerivedFacts.isEmpty)

        await service.recordFireTimeReached(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.now.addingTimeInterval(60)
        )
        await service.recordOpenedFromNotification(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.now.addingTimeInterval(-60)
        )

        let events = await repository.events(limit: nil)
        XCTAssertEqual(Set(events.map(\.type)), [.fireTimeReached, .openedFromNotification])
    }

    func testBestEffortRecordSwallowsLedgerFailure() async {
        let service = AgentLedgerService(repository: FailingAgentLedgerRepository())

        await service.recordScheduled(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.fireAt
        )

        do {
            _ = try await service.events()
            XCTFail("The failure double should still fail explicit reads.")
        } catch {
            XCTAssertEqual(error as? FailingAgentLedgerRepositoryError, .forced)
        }
    }

    func testBestEffortRecordDeduplicatesRetriesAndKeepsTypedCancellationFacts() async throws {
        let repository = InMemoryAgentLedgerRepository()
        let service = AgentLedgerService(
            repository: repository,
            now: { Self.now },
            makeID: { UUID() }
        )

        await service.recordScheduled(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.fireAt
        )
        await service.recordScheduled(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.fireAt
        )
        await service.recordCancelled(
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            scheduledFor: Self.fireAt,
            reason: .actionItemCompleted
        )

        let events = try await service.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.filter { $0.type == .scheduled }.count, 1)
        let cancellation = try XCTUnwrap(events.first { $0.type == .cancelled }?.cancellation)
        XCTAssertEqual(cancellation.source, .policy)
        XCTAssertEqual(cancellation.reason, .actionItemCompleted)
    }

    private func makeEvent(
        id: UUID = AgentLedgerTests.eventID,
        type: AgentLedgerEventType = .scheduled,
        occurredAt: Date = AgentLedgerTests.now,
        deduplicationKey: String = "scheduled:fixed",
        cancellation: AgentLedgerCancellation? = nil,
        feedback: AgentLedgerFeedback? = nil
    ) -> AgentLedgerEvent {
        AgentLedgerEvent(
            id: id,
            deduplicationKey: deduplicationKey,
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            type: type,
            occurredAt: occurredAt,
            scheduledFor: Self.fireAt,
            cancellation: cancellation,
            feedback: feedback
        )
    }
}
