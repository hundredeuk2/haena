import Foundation

/// Storage for the private beta measurement facts.
///
/// Three operations, no update and no delete-one: a measurement fact is either recorded once or
/// the whole measurement is reset. Anything finer would let the numbers be edited after the fact,
/// which is exactly what makes a self-reported beta metric worthless.
protocol BetaMetricsRepository: Sendable {
    /// Returns the already-stored event when `deduplicationKey` has been seen, so a retried write
    /// is a no-op rather than a second count. The caller cannot tell the two apart — deliberately,
    /// since no caller should behave differently.
    @discardableResult
    func append(_ event: BetaMetricEvent) async throws -> BetaMetricEvent
    func store() async throws -> BetaMetricsStoreFile
    /// Starts a new measurement period at `timestamp` and drops every event recorded before it.
    func reset(at timestamp: Date) async throws
}

/// The on-disk store, beside `projects.json` and `agent-ledger.json` in the app's own directory.
///
/// Same guarantees as `JSONAgentLedgerRepository`, for the same reasons: an atomic replace so a
/// crash mid-write cannot leave a half-file, `0600` so nothing but this user's account can read it,
/// and a schema version that refuses to guess at a file it does not understand.
actor JSONBetaMetricsRepository: BetaMetricsRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var cache: BetaMetricsStoreFile?

    /// `now` stamps the measurement start the first time a store is created — i.e. the beta period
    /// begins when the app first has something to measure, not at some install date it never saw.
    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        JSONProjectRepository.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("beta-metrics.json")
    }

    @discardableResult
    func append(_ event: BetaMetricEvent) throws -> BetaMetricEvent {
        let isCreatingStore = !fileManager.fileExists(atPath: fileURL.path)
        var store = try loadIfNeeded()
        if let existing = store.events.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }

        // A measurement period must not begin after the first thing it measures.
        //
        // The start is stamped lazily, from this actor's clock, at the moment the store is first
        // materialised — but the event was built earlier, from the *caller's* clock. Any gap between
        // the two, even a few microseconds of ordinary execution, put `measurementStartedAt` after
        // the very first event and the window filter then dropped it: the user's first processed
        // meeting never counted toward activation or a usage day, and nothing on the screen could
        // explain why.
        //
        // Only ever lowered, and only while creating the store. An existing file's start, the
        // boundary `reset(at:)` established, and the start a dashboard read already settled on are
        // all preserved — `min` cannot move any of them forward, and a start that legitimately
        // precedes this event is already correct.
        if isCreatingStore, store.events.isEmpty {
            store.measurementStartedAt = min(store.measurementStartedAt, event.occurredAt)
        }

        store.events.append(event)
        try persist(store)
        cache = store
        return event
    }

    func store() throws -> BetaMetricsStoreFile {
        let loaded = try loadIfNeeded()
        return BetaMetricsStoreFile(
            schemaVersion: loaded.schemaVersion,
            measurementStartedAt: loaded.measurementStartedAt,
            events: Self.oldestFirst(loaded.events)
        )
    }

    func reset(at timestamp: Date) throws {
        let store = BetaMetricsStoreFile(measurementStartedAt: timestamp, events: [])
        try persist(store)
        cache = store
    }

    /// An absent file is an empty measurement, not an error — the store is created on first write.
    /// The empty value is cached but not persisted, so merely reading the beta screen never leaves
    /// a file behind on a machine that has recorded nothing.
    private func loadIfNeeded() throws -> BetaMetricsStoreFile {
        if let cache { return cache }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = BetaMetricsStoreFile(measurementStartedAt: now())
            cache = empty
            return empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw JSONRepositoryError.readFailed(underlying: String(describing: error))
        }
        let store: BetaMetricsStoreFile
        do {
            store = try JSONDecoder().decode(BetaMetricsStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }
        guard store.schemaVersion == BetaMetricsStoreFile.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: BetaMetricsStoreFile.currentSchemaVersion
            )
        }

        // Defensive normalization for a hand-edited or partially written file: oldest fact for a
        // deduplication key wins, matching what `append` would have done had the duplicates arrived
        // in order. Without this, a file with two verdicts for one proposal could report a different
        // approval rate depending on how the decoder happened to order them.
        var seenKeys = Set<String>()
        let normalized = Self.oldestFirst(store.events)
            .filter { seenKeys.insert($0.deduplicationKey).inserted }
        let normalizedStore = BetaMetricsStoreFile(
            schemaVersion: store.schemaVersion,
            measurementStartedAt: store.measurementStartedAt,
            events: normalized
        )
        cache = normalizedStore
        return normalizedStore
    }

    private func persist(_ store: BetaMetricsStoreFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JSONRepositoryError.directoryCreationFailed(underlying: String(describing: error))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                BetaMetricsStoreFile(
                    schemaVersion: store.schemaVersion,
                    measurementStartedAt: store.measurementStartedAt,
                    events: Self.oldestFirst(store.events)
                )
            )
        } catch {
            throw JSONRepositoryError.encodingFailed(underlying: String(describing: error))
        }

        let temporaryURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            // Keep the contract explicit even on file systems where replace preserves old mode.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }
    }

    private static func oldestFirst(_ events: [BetaMetricEvent]) -> [BetaMetricEvent] {
        events.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// Test and preview double. Defaults to a measurement that started at `.distantPast` so seeded
/// events are inside the window unless a test is specifically about the window boundary.
actor InMemoryBetaMetricsRepository: BetaMetricsRepository {
    private var measurementStartedAt: Date
    private var stored: [BetaMetricEvent]

    init(measurementStartedAt: Date = .distantPast, events: [BetaMetricEvent] = []) {
        self.measurementStartedAt = measurementStartedAt
        self.stored = events
    }

    @discardableResult
    func append(_ event: BetaMetricEvent) -> BetaMetricEvent {
        if let existing = stored.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }
        stored.append(event)
        return event
    }

    func store() -> BetaMetricsStoreFile {
        BetaMetricsStoreFile(
            measurementStartedAt: measurementStartedAt,
            events: stored.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        )
    }

    func reset(at timestamp: Date) {
        stored = []
        measurementStartedAt = timestamp
    }
}

enum FailingBetaMetricsRepositoryError: Error, Equatable, Sendable {
    case forced
}

/// Proves the one property that matters most about this subsystem: when metrics storage is broken,
/// the flows being measured carry on regardless. Every `BetaMetricsService.record*` call swallows
/// what this double throws; only the user-initiated reset and the beta screen's own read surface it.
actor FailingBetaMetricsRepository: BetaMetricsRepository {
    func append(_ event: BetaMetricEvent) throws -> BetaMetricEvent { throw FailingBetaMetricsRepositoryError.forced }
    func store() throws -> BetaMetricsStoreFile { throw FailingBetaMetricsRepositoryError.forced }
    func reset(at timestamp: Date) throws { throw FailingBetaMetricsRepositoryError.forced }
}
