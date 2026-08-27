import XCTest
@testable import HAENA

/// Covers the recording half of the beta measurement: what a fact is keyed on, what happens when
/// the same fact arrives twice, what survives a restart, and what a reset really erases.
///
/// The recurring theme is that a metric is only worth reading if it cannot be inflated by ordinary
/// app behaviour — a retried run, a re-opened review sheet, a user who edits the same date twice.
final class BetaMetricsDomainTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let projectID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    private static let meetingID = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
    private static let proposalID = UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
    private static let runID = UUID(uuidString: "31000000-0000-0000-0000-000000000004")!
    private static let eventID = UUID(uuidString: "31000000-0000-0000-0000-0000000000A1")!
    private static let otherEventID = UUID(uuidString: "31000000-0000-0000-0000-0000000000A2")!

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-BetaMetrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    // MARK: - The measurement period cannot start after what it measures

    /// The regression this suite exists for.
    ///
    /// The event is built from the *caller's* clock; the store stamps its start from the
    /// *repository's* clock, lazily, when the file is first created. Any gap between the two put the
    /// start after the very first event, the window filter dropped it, and the user's first
    /// processed meeting never counted toward activation or a usage day. Two deliberately different
    /// clocks reproduce that gap exactly.
    func testTheFirstEventIsInsideTheWindowEvenWhenTheStoreClockRunsLater() async throws {
        let eventTime = Self.now
        let repositoryTime = Self.now.addingTimeInterval(5)
        let repository = JSONBetaMetricsRepository(
            fileURL: directory.appendingPathComponent("beta-metrics.json"),
            now: { repositoryTime }
        )
        let service = BetaMetricsService(
            repository: repository,
            now: { eventTime },
            makeID: { Self.eventID }
        )

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 2
        )

        let store = try await repository.store()
        XCTAssertLessThanOrEqual(
            store.measurementStartedAt,
            eventTime,
            "A measurement period must not begin after the first thing it measures"
        )

        let summary = try await service.summary(calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 1, "The first meeting is inside the window")
        XCTAssertTrue(summary.isActivated, "…so it activates immediately")
        XCTAssertEqual(summary.distinctUsageDays, 1, "…and counts as a usage day")
    }

    /// The lowering is only ever a repair of the store's own lazy stamp. An existing file already
    /// has a start the user's report has been quoting, and a late-arriving event must not drag it
    /// backwards into a period the report never covered.
    func testAnExistingMeasurementStartIsNeverMovedBackwardsByALaterEvent() async throws {
        let fileURL = directory.appendingPathComponent("beta-metrics.json")
        let established = Self.now
        let repository = JSONBetaMetricsRepository(fileURL: fileURL, now: { established })
        let first = BetaMetricsService(repository: repository, now: { established }, makeID: { Self.eventID })
        await first.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 1
        )

        // A fresh repository over the same file, handed an event stamped before the stored start.
        let reopened = JSONBetaMetricsRepository(fileURL: fileURL, now: { established })
        let stale = BetaMetricsService(
            repository: reopened,
            now: { established.addingTimeInterval(-3_600) },
            makeID: { Self.otherEventID }
        )
        await stale.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: UUID(uuidString: "31000000-0000-0000-0000-0000000000B1")!,
            source: .pastedText,
            resultCount: 1
        )

        let store = try await reopened.store()
        XCTAssertEqual(store.measurementStartedAt, established, "The stored start is preserved")
        let insideWindow = store.events.filter { $0.occurredAt >= store.measurementStartedAt }
        XCTAssertEqual(
            insideWindow.count,
            1,
            "The stale event stays outside the window rather than redefining it"
        )
    }

    /// `reset(at:)` is the erasure boundary the user was promised. An event stamped before it — a
    /// call already in flight when they pressed the button — must not pull the boundary back and
    /// resurrect the period they just erased.
    func testResetBoundaryIsNotMovedBackwardsByAnEventFromBeforeIt() async throws {
        let fileURL = directory.appendingPathComponent("beta-metrics.json")
        let repository = JSONBetaMetricsRepository(fileURL: fileURL, now: { Self.now })
        let resetAt = Self.now.addingTimeInterval(600)
        try await repository.reset(at: resetAt)

        let late = BetaMetricsService(
            repository: repository,
            now: { Self.now },
            makeID: { Self.eventID }
        )
        await late.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 1
        )

        let store = try await repository.store()
        XCTAssertEqual(store.measurementStartedAt, resetAt, "The reset boundary stands")

        let summary = try await late.summary(calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 0, "Nothing from before the reset is counted again")
    }

    /// Opening the dashboard settles a start date the user has now seen. Recording something
    /// afterwards must keep it, not silently re-date the period around the new event.
    func testAStartSettledByReadingTheDashboardSurvivesTheFirstRecording() async throws {
        let fileURL = directory.appendingPathComponent("beta-metrics.json")
        let readAt = Self.now
        let repository = JSONBetaMetricsRepository(fileURL: fileURL, now: { readAt })

        let observed = try await repository.store().measurementStartedAt
        XCTAssertEqual(observed, readAt)

        let service = BetaMetricsService(
            repository: repository,
            now: { readAt.addingTimeInterval(120) },
            makeID: { Self.eventID }
        )
        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 1
        )

        let store = try await repository.store()
        XCTAssertEqual(store.measurementStartedAt, observed, "The date the user was shown is kept")
        let summary = try await service.summary(calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 1, "…and the event is still inside the window")
    }

    // MARK: - Retries must not double count

    /// The headline storage rule. A processing run that is retried, a review sheet re-submitted, or
    /// a record call issued twice by two code paths, all describe one real-world act — and a beta
    /// metric that counts them twice reports a product being used more than it was.
    func testTheSameFactRecordedTwiceIsStoredOnce() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = makeService(repository: repository)

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .recordedAudio,
            resultCount: 7
        )
        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .recordedAudio,
            resultCount: 7
        )

        let store = await repository.store()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events.first?.resultCount, 7)

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 1, "One meeting, however many times it was processed")
    }

    /// Deduplication is on the key, not on the event's own identity or timestamp: a retry a minute
    /// later is a different `id` and a different `occurredAt`, and must still lose to the original.
    func testDeduplicationIgnoresIdentityAndTimestampAndKeepsTheFirstFact() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let first = BetaMetricEvent(
            id: Self.eventID,
            deduplicationKey: "meetingProcessed:fixed",
            type: .meetingProcessed,
            occurredAt: Self.now,
            meetingID: Self.meetingID
        )
        let retry = BetaMetricEvent(
            id: Self.otherEventID,
            deduplicationKey: "meetingProcessed:fixed",
            type: .meetingProcessed,
            occurredAt: Self.now.addingTimeInterval(60),
            meetingID: Self.meetingID
        )

        let storedFirst = await repository.append(first)
        let storedRetry = await repository.append(retry)

        XCTAssertEqual(storedFirst, first)
        XCTAssertEqual(storedRetry, first, "The caller is handed the original, not its own event")
        let store = await repository.store()
        XCTAssertEqual(store.events, [first])
    }

    /// A user who nudges one due date three times, then fixes its assignee too, has found one bad
    /// proposal — not four. The modification rate answers "how often does the model need
    /// correcting", so it counts proposals, and the key is the proposal alone.
    func testAProposalEditedRepeatedlyAndInSeveralFieldsCountsOnce() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = makeService(repository: repository)

        for _ in 0..<3 {
            await service.recordProposalModified(
                projectID: Self.projectID,
                proposalID: Self.proposalID,
                kind: .actionItem,
                field: .dueDate
            )
        }
        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            field: .assignee
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            verdict: .approved
        )

        let store = await repository.store()
        let modifications = store.events.filter { $0.type == .proposalModified }
        XCTAssertEqual(
            modifications.count,
            2,
            "One fact per corrected field: the repeated due-date edits collapse, the assignee survives"
        )
        XCTAssertEqual(
            Set(modifications.compactMap(\.fieldCategory)),
            [.dueDate, .assignee],
            "Neither field suppresses the other"
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.modifiedProposals, 1)
        XCTAssertEqual(summary.modificationRate, 1.0)
    }

    /// The first verdict wins. Approving an item today and deleting it next month is a change of
    /// mind about the work; the extraction was already judged, and re-judging it would let the
    /// approval rate drift with ordinary project churn.
    func testTheFirstVerdictOnAProposalIsTheOneKept() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = makeService(repository: repository)

        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .decision,
            verdict: .approved
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .decision,
            verdict: .excluded
        )

        let summary = BetaMetricsSummary(store: await repository.store(), calendar: Self.utcCalendar)
        XCTAssertEqual(summary.reviewedProposals, 1)
        XCTAssertEqual(summary.approvedCount, 1)
        XCTAssertEqual(summary.excludedCount, 0)
    }

    /// Two attempts at the same recording are two waits the user actually sat through, so duration
    /// is keyed on the run and not on the meeting. A failed attempt has no meeting at all.
    func testEachProcessingAttemptIsItsOwnDurationSample() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = makeService(repository: repository)
        let secondRun = UUID(uuidString: "31000000-0000-0000-0000-000000000005")!

        await service.recordProcessingDuration(
            runID: Self.runID,
            source: .importedAudio,
            outcome: .failed,
            milliseconds: 4_000,
            meetingID: nil
        )
        await service.recordProcessingDuration(
            runID: Self.runID,
            source: .importedAudio,
            outcome: .failed,
            milliseconds: 4_000,
            meetingID: nil
        )
        await service.recordProcessingDuration(
            runID: secondRun,
            source: .importedAudio,
            outcome: .succeeded,
            milliseconds: 9_000,
            meetingID: Self.meetingID
        )

        let summary = BetaMetricsSummary(store: await repository.store(), calendar: Self.utcCalendar)
        XCTAssertEqual(summary.durationSampleCount, 2, "One per attempt; the retried write is not a third")
        XCTAssertEqual(
            summary.medianDurationMilliseconds,
            6_500,
            "Arithmetic mean of the two samples, 4,000 and 9,000"
        )
    }

    // MARK: - Storage

    /// The report is read from disk on every launch, so a store written and read back has to yield
    /// the identical summary — a beta whose numbers change across a restart is not a measurement.
    /// A file written before `extractionPhase` existed must still decode, and a file with the new
    /// rows must round-trip. The field is additive and optional and the store stays on schema 1,
    /// so no existing `beta-metrics.json` is stranded by this investigation.
    func testASchemaOneFileWithoutThePhaseFieldStillDecodesAndRoundTrips() throws {
        let legacy = """
        {"schemaVersion":1,"measurementStartedAt":0,"events":[{\
        "id":"55000000-0000-4000-8000-000000000001",\
        "deduplicationKey":"meetingProcessed:55000000-0000-4000-8000-000000000002",\
        "type":"meetingProcessed","occurredAt":0,\
        "meetingID":"55000000-0000-4000-8000-000000000002"}]}
        """
        let decoded = try JSONDecoder().decode(
            BetaMetricsStoreFile.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertNil(decoded.events[0].extractionPhase)

        var withPhase = decoded
        withPhase.events.append(
            BetaMetricEvent(
                id: UUID(uuidString: "55000000-0000-4000-8000-000000000003")!,
                deduplicationKey: "extractionPhase:55000000-0000-4000-8000-000000000004:projectSaved",
                type: .extractionPhase,
                occurredAt: Date(timeIntervalSinceReferenceDate: 0),
                durationMilliseconds: 1_200,
                extractionPhase: .projectSaved
            )
        )
        let reencoded = try JSONEncoder().encode(withPhase)
        let roundTripped = try JSONDecoder().decode(BetaMetricsStoreFile.self, from: reencoded)
        XCTAssertEqual(roundTripped, withPhase)
        XCTAssertEqual(roundTripped.events.last?.extractionPhase, .projectSaved)
        XCTAssertEqual(roundTripped.schemaVersion, 1)
    }

    /// The three new markers are additive to the same optional field on the same schema 1 store, so
    /// a file written before they existed must still decode and a row naming one must round-trip.
    /// The logical order is asserted from `sequence` rather than from declaration order, because
    /// readers sort by it and inserting a case in the middle is exactly what happened here.
    func testTheCredentialPhasesRoundTripAndOrderBeforeTheProviderReturn() throws {
        let phases: [BetaMetricExtractionPhase] = [
            .extractionStarted,
            .credentialResolutionStarted,
            .credentialResolved,
            .requestDispatched,
            .providerReturned,
            .projectSaved,
            .transitionRecordReturned,
            .applyReturned,
            .runExtractionExited,
            .outcomeShown
        ]
        XCTAssertEqual(BetaMetricExtractionPhase.allCases, phases)
        XCTAssertEqual(phases.map(\.sequence), Array(1...phases.count))

        var file = BetaMetricsStoreFile(
            schemaVersion: 1,
            measurementStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            events: []
        )
        for phase in [BetaMetricExtractionPhase.credentialResolutionStarted, .credentialResolved, .requestDispatched] {
            file.events.append(
                BetaMetricEvent(
                    id: UUID(),
                    deduplicationKey: "extractionPhase:55000000-0000-4000-8000-000000000005:\(phase.rawValue)",
                    type: .extractionPhase,
                    occurredAt: Date(timeIntervalSinceReferenceDate: 0),
                    durationMilliseconds: 1,
                    extractionPhase: phase
                )
            )
        }
        let roundTripped = try JSONDecoder().decode(
            BetaMetricsStoreFile.self,
            from: try JSONEncoder().encode(file)
        )
        XCTAssertEqual(roundTripped, file)
        XCTAssertEqual(roundTripped.schemaVersion, 1)
    }

    func testTheSummaryIsUnchangedAfterAJSONRoundTrip() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let writer = JSONBetaMetricsRepository(fileURL: url, now: { Self.now })
        let service = makeService(repository: writer)

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 3
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .openQuestion,
            verdict: .approved
        )
        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .openQuestion,
            field: .assignee
        )
        await service.recordProcessingDuration(
            runID: Self.runID,
            source: .pastedText,
            outcome: .succeeded,
            milliseconds: 2_500,
            meetingID: Self.meetingID
        )

        let written = try await writer.store()
        let reloaded = try await JSONBetaMetricsRepository(fileURL: url, now: { Self.now.addingTimeInterval(999) }).store()

        XCTAssertEqual(reloaded, written, "Including the measurement start — a reload must not restamp it")
        XCTAssertEqual(
            BetaMetricsSummary(store: reloaded, calendar: Self.utcCalendar),
            BetaMetricsSummary(store: written, calendar: Self.utcCalendar)
        )

        let decoded = try JSONDecoder().decode(BetaMetricsStoreFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(decoded.schemaVersion, 1, "The envelope is versioned so a future schema is refused, not guessed")
    }

    /// The store sits beside `projects.json` and holds a record of how someone worked. It is created
    /// with its directory and readable by nobody but this account.
    func testTheStoreIsWrittenPrivatelyAndCreatesItsOwnDirectory() async throws {
        let nested = directory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.haena.HAENA", isDirectory: true)
        let url = nested.appendingPathComponent("beta-metrics.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        let repository = JSONBetaMetricsRepository(fileURL: url, now: { Self.now })
        await makeService(repository: repository).recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .recordedAudio,
            resultCount: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// Reading the beta screen on a machine that has recorded nothing must not leave a file behind:
    /// an empty measurement is a state, not a thing to write down.
    func testReadingAnEmptyStoreDoesNotCreateAFile() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let store = try await JSONBetaMetricsRepository(fileURL: url, now: { Self.now }).store()

        XCTAssertEqual(store.events, [])
        XCTAssertEqual(store.measurementStartedAt, Self.now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnUnsupportedSchemaIsRefusedRatherThanGuessedAt() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let data = try JSONEncoder().encode(
            BetaMetricsStoreFile(schemaVersion: 99, measurementStartedAt: Self.now, events: [])
        )
        try data.write(to: url)

        do {
            _ = try await JSONBetaMetricsRepository(fileURL: url).store()
            XCTFail("Expected an unsupported schema to fail.")
        } catch let error as JSONRepositoryError {
            guard case .unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, 1)
        }
    }

    /// A hand-edited file holding two verdicts for one proposal must not report a different approval
    /// rate depending on the order the decoder happened to produce.
    func testAFileWithDuplicateKeysIsNormalisedToTheOldestFact() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let approved = BetaMetricEvent(
            id: Self.eventID,
            deduplicationKey: "proposalReviewed:duplicated",
            type: .proposalReviewed,
            occurredAt: Self.now,
            proposalID: Self.proposalID,
            proposalKind: .decision,
            verdict: .approved
        )
        let laterExclusion = BetaMetricEvent(
            id: Self.otherEventID,
            deduplicationKey: "proposalReviewed:duplicated",
            type: .proposalReviewed,
            occurredAt: Self.now.addingTimeInterval(60),
            proposalID: Self.proposalID,
            proposalKind: .decision,
            verdict: .excluded
        )
        let data = try JSONEncoder().encode(
            BetaMetricsStoreFile(measurementStartedAt: Self.now, events: [laterExclusion, approved])
        )
        try data.write(to: url)

        let store = try await JSONBetaMetricsRepository(fileURL: url).store()
        XCTAssertEqual(store.events, [approved])
    }

    // MARK: - Reset

    /// What "reset" has to mean for a user who presses it: the old facts are gone from disk, not
    /// merely hidden behind a new start date, and a fresh process cannot bring them back.
    func testResetErasesPastEventsIrrecoverablyAndMovesTheMeasurementStart() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let resetAt = Self.now.addingTimeInterval(86_400)
        let repository = JSONBetaMetricsRepository(fileURL: url, now: { Self.now })
        await makeService(repository: repository).recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 2
        )
        let beforeReset = try await repository.store()
        XCTAssertEqual(beforeReset.events.count, 1)

        try await makeService(repository: repository, now: resetAt).reset()

        let onDisk = try JSONDecoder().decode(BetaMetricsStoreFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(onDisk.events, [], "Erased from the file itself, not filtered out on read")
        XCTAssertEqual(onDisk.measurementStartedAt, resetAt)

        let afterRelaunch = try await JSONBetaMetricsRepository(fileURL: url).store()
        XCTAssertEqual(afterRelaunch.events, [])
        XCTAssertEqual(afterRelaunch.measurementStartedAt, resetAt)

        let summary = BetaMetricsSummary(store: afterRelaunch, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 0)
        XCTAssertFalse(summary.isActivated)
        XCTAssertEqual(summary.measurementStartedAt, resetAt)
    }

    // MARK: - Failure is never the caller's problem

    /// The point of the whole design. With storage broken, every recording call still returns
    /// normally — there is no error for a capture or a review flow to propagate, so measurement
    /// cannot be the reason a user's work fails.
    func testRecordingSwallowsEveryStorageFailure() async {
        let service = BetaMetricsService(
            repository: FailingBetaMetricsRepository(),
            now: { Self.now },
            makeID: { Self.eventID }
        )

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 1
        )
        await service.recordProcessingDuration(
            runID: Self.runID,
            source: .pastedText,
            outcome: .succeeded,
            milliseconds: 10,
            meetingID: Self.meetingID
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .agendaItem,
            verdict: .approved
        )
        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .agendaItem,
            field: .assignee
        )
    }

    /// The two operations the user asked for by name do surface their failure, because a silent
    /// "erased" that erased nothing, or an empty report that is really a broken read, would both be
    /// lies told to someone's face.
    func testResetAndSummaryReportTheirFailures() async {
        let service = BetaMetricsService(repository: FailingBetaMetricsRepository(), now: { Self.now })

        do {
            try await service.reset()
            XCTFail("A failed erasure must be told to the user who requested it.")
        } catch {
            XCTAssertEqual(error as? FailingBetaMetricsRepositoryError, .forced)
        }

        do {
            _ = try await service.summary(calendar: Self.utcCalendar)
            XCTFail("A broken read must not be shown as an empty report.")
        } catch {
            XCTAssertEqual(error as? FailingBetaMetricsRepositoryError, .forced)
        }
    }

    /// The reminder ledger is another feature's store. If it cannot be read the beta report still
    /// stands on its own numbers — note that this is exactly why an unreadable ledger looks like a
    /// user who never gave feedback, and why feedback counts must never be presented as proof that
    /// nobody had an opinion.
    func testAnUnreadableLedgerDoesNotTakeTheReportDownWithIt() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = BetaMetricsService(
            repository: repository,
            ledgerRepository: FailingAgentLedgerRepository(),
            now: { Self.now },
            makeID: { Self.eventID }
        )
        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .pastedText,
            resultCount: 1
        )

        let summary = try await service.summary(calendar: Self.utcCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 1, "The metrics this service owns are unaffected")
        XCTAssertEqual(
            summary.agentFeedback,
            .unavailable,
            "A ledger that refuses to be read is reported as unavailable, never as an empty tally"
        )
        XCTAssertFalse(summary.isAgentFeedbackAvailable)
        XCTAssertNil(
            summary.agentFeedbackCount(.helpful),
            "There is no evidence for a zero, so none is offered"
        )
    }

    // MARK: - Corrections are keyed on the proposal and the field

    /// Nudging the same field repeatedly is one fault found, not five.
    func testTheSameFieldCorrectedRepeatedlyIsStoredOnce() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = BetaMetricsService(repository: repository, now: { Self.now }, makeID: { UUID() })

        for _ in 0..<3 {
            await service.recordProposalModified(
                projectID: Self.projectID,
                proposalID: Self.proposalID,
                kind: .actionItem,
                field: .dueDate
            )
        }

        let events = try await repository.store().events.filter { $0.type == .proposalModified }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.fieldCategory, .dueDate)
    }

    /// Both fields wrong on one proposal is two facts about the extraction, and keying on the
    /// proposal alone silently kept only whichever the caller emitted first — making the field
    /// breakdown a record of emission order rather than of what the model got wrong.
    func testCorrectingBothFieldsKeepsBothCategories() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = BetaMetricsService(repository: repository, now: { Self.now }, makeID: { UUID() })

        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            field: .assignee
        )
        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            field: .dueDate
        )

        let events = try await repository.store().events.filter { $0.type == .proposalModified }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            Set(events.compactMap(\.fieldCategory)),
            [.assignee, .dueDate],
            "Both categories survive"
        )
        XCTAssertEqual(
            Set(events.map(\.deduplicationKey)).count,
            2,
            "Two distinct keys, so neither suppresses the other"
        )
    }

    /// …and the rate is unaffected, because the numerator counts proposals rather than events. This
    /// is the property that let the key change be safe at all.
    func testCorrectingBothFieldsStillCountsAsOneModifiedProposal() async throws {
        let repository = InMemoryBetaMetricsRepository(measurementStartedAt: Self.now)
        let service = BetaMetricsService(repository: repository, now: { Self.now }, makeID: { UUID() })

        for field in BetaMetricFieldCategory.allCases {
            await service.recordProposalModified(
                projectID: Self.projectID,
                proposalID: Self.proposalID,
                kind: .actionItem,
                field: field
            )
        }
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            verdict: .approved
        )

        let summary = try await service.summary(calendar: Self.utcCalendar)
        XCTAssertEqual(summary.modifiedProposals, 1, "One proposal needed correcting, not two")
        XCTAssertEqual(summary.reviewedProposals, 1)
        XCTAssertEqual(summary.modificationRate, 1.0)
    }

    // MARK: - Helpers

    private func makeService(
        repository: any BetaMetricsRepository,
        ledgerRepository: (any AgentLedgerRepository)? = nil,
        now: Date = BetaMetricsDomainTests.now
    ) -> BetaMetricsService {
        BetaMetricsService(
            repository: repository,
            ledgerRepository: ledgerRepository,
            now: { now },
            makeID: { UUID() }
        )
    }
}
