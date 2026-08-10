import Foundation

protocol AgentLedgerRepository: Sendable {
    @discardableResult
    func append(_ event: AgentLedgerEvent) async throws -> AgentLedgerEvent
    /// Atomically applies the clear watermark to reconcile-derived facts.
    @discardableResult
    func appendDerived(
        _ event: AgentLedgerEvent,
        sourceOccurredAt: Date
    ) async throws -> AgentLedgerEvent?
    func events(limit: Int?) async throws -> [AgentLedgerEvent]
    @discardableResult
    func upsertFeedback(_ event: AgentLedgerEvent) async throws -> AgentLedgerEvent
    func clearFeedback(for reminderID: UUID) async throws
    func clear(at timestamp: Date) async throws
}

actor JSONAgentLedgerRepository: AgentLedgerRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: AgentLedgerStoreFile?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        JSONProjectRepository.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-ledger.json")
    }

    @discardableResult
    func append(_ event: AgentLedgerEvent) throws -> AgentLedgerEvent {
        var store = try loadIfNeeded()
        if let existing = store.events.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }
        store.events.append(event)
        try persist(store)
        cache = store
        return event
    }

    @discardableResult
    func appendDerived(
        _ event: AgentLedgerEvent,
        sourceOccurredAt: Date
    ) throws -> AgentLedgerEvent? {
        var store = try loadIfNeeded()
        if let clearedAt = store.clearedAt, sourceOccurredAt <= clearedAt {
            return nil
        }
        if let existing = store.events.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }
        store.events.append(event)
        try persist(store)
        cache = store
        return event
    }

    func events(limit: Int?) throws -> [AgentLedgerEvent] {
        let ordered = Self.mostRecentFirst(try loadIfNeeded().events)
        guard let limit else { return ordered }
        return Array(ordered.prefix(max(0, limit)))
    }

    @discardableResult
    func upsertFeedback(_ event: AgentLedgerEvent) throws -> AgentLedgerEvent {
        precondition(event.type == .feedback && event.feedback != nil)
        var store = try loadIfNeeded()
        if let index = store.events.firstIndex(where: {
            $0.type == .feedback && $0.reminderID == event.reminderID
        }) {
            let existing = store.events[index]
            let updated = AgentLedgerEvent(
                id: existing.id,
                deduplicationKey: existing.deduplicationKey,
                reminderID: event.reminderID,
                projectID: event.projectID,
                actionItemID: event.actionItemID,
                type: .feedback,
                occurredAt: event.occurredAt,
                scheduledFor: event.scheduledFor,
                feedback: event.feedback
            )
            store.events[index] = updated
            try persist(store)
            cache = store
            return updated
        }
        store.events.append(event)
        try persist(store)
        cache = store
        return event
    }

    func clearFeedback(for reminderID: UUID) throws {
        var store = try loadIfNeeded()
        store.events.removeAll { $0.type == .feedback && $0.reminderID == reminderID }
        try persist(store)
        cache = store
    }

    func clear(at timestamp: Date) throws {
        let store = AgentLedgerStoreFile(clearedAt: timestamp, events: [])
        try persist(store)
        cache = store
    }

    private func loadIfNeeded() throws -> AgentLedgerStoreFile {
        if let cache { return cache }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = AgentLedgerStoreFile()
            cache = empty
            return empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw JSONRepositoryError.readFailed(underlying: String(describing: error))
        }
        let store: AgentLedgerStoreFile
        do {
            store = try JSONDecoder().decode(AgentLedgerStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }
        guard store.schemaVersion == AgentLedgerStoreFile.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: AgentLedgerStoreFile.currentSchemaVersion
            )
        }

        // Defensive normalization for hand-edited or legacy files: first dedup key wins, while the
        // most recent feedback is the sole feedback fact retained for a reminder.
        var seenKeys = Set<String>()
        var normalized: [AgentLedgerEvent] = []
        for event in Self.oldestFirst(store.events) where seenKeys.insert(event.deduplicationKey).inserted {
            if event.type == .feedback {
                normalized.removeAll { $0.type == .feedback && $0.reminderID == event.reminderID }
            }
            normalized.append(event)
        }
        let normalizedStore = AgentLedgerStoreFile(
            schemaVersion: store.schemaVersion,
            clearedAt: store.clearedAt,
            events: normalized
        )
        cache = normalizedStore
        return normalizedStore
    }

    private func persist(_ store: AgentLedgerStoreFile) throws {
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
                AgentLedgerStoreFile(
                    schemaVersion: store.schemaVersion,
                    clearedAt: store.clearedAt,
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

    private static func mostRecentFirst(_ events: [AgentLedgerEvent]) -> [AgentLedgerEvent] {
        events.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private static func oldestFirst(_ events: [AgentLedgerEvent]) -> [AgentLedgerEvent] {
        events.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

actor InMemoryAgentLedgerRepository: AgentLedgerRepository {
    private var stored: [AgentLedgerEvent]
    private var clearedAt: Date?

    init(events: [AgentLedgerEvent] = [], clearedAt: Date? = nil) {
        self.stored = events
        self.clearedAt = clearedAt
    }

    @discardableResult
    func append(_ event: AgentLedgerEvent) -> AgentLedgerEvent {
        if let existing = stored.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }
        stored.append(event)
        return event
    }

    @discardableResult
    func appendDerived(
        _ event: AgentLedgerEvent,
        sourceOccurredAt: Date
    ) -> AgentLedgerEvent? {
        if let clearedAt, sourceOccurredAt <= clearedAt { return nil }
        if let existing = stored.first(where: { $0.deduplicationKey == event.deduplicationKey }) {
            return existing
        }
        stored.append(event)
        return event
    }

    func events(limit: Int?) -> [AgentLedgerEvent] {
        let ordered = stored.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString > $1.id.uuidString
        }
        guard let limit else { return ordered }
        return Array(ordered.prefix(max(0, limit)))
    }

    @discardableResult
    func upsertFeedback(_ event: AgentLedgerEvent) -> AgentLedgerEvent {
        precondition(event.type == .feedback && event.feedback != nil)
        if let index = stored.firstIndex(where: {
            $0.type == .feedback && $0.reminderID == event.reminderID
        }) {
            let existing = stored[index]
            let updated = AgentLedgerEvent(
                id: existing.id,
                deduplicationKey: existing.deduplicationKey,
                reminderID: event.reminderID,
                projectID: event.projectID,
                actionItemID: event.actionItemID,
                type: .feedback,
                occurredAt: event.occurredAt,
                scheduledFor: event.scheduledFor,
                feedback: event.feedback
            )
            stored[index] = updated
            return updated
        }
        stored.append(event)
        return event
    }

    func clearFeedback(for reminderID: UUID) {
        stored.removeAll { $0.type == .feedback && $0.reminderID == reminderID }
    }

    func clear(at timestamp: Date) {
        stored = []
        clearedAt = timestamp
    }
}

enum FailingAgentLedgerRepositoryError: Error, Equatable, Sendable {
    case forced
}

actor FailingAgentLedgerRepository: AgentLedgerRepository {
    func append(_ event: AgentLedgerEvent) throws -> AgentLedgerEvent { throw FailingAgentLedgerRepositoryError.forced }
    func appendDerived(_ event: AgentLedgerEvent, sourceOccurredAt: Date) throws -> AgentLedgerEvent? { throw FailingAgentLedgerRepositoryError.forced }
    func events(limit: Int?) throws -> [AgentLedgerEvent] { throw FailingAgentLedgerRepositoryError.forced }
    func upsertFeedback(_ event: AgentLedgerEvent) throws -> AgentLedgerEvent { throw FailingAgentLedgerRepositoryError.forced }
    func clearFeedback(for reminderID: UUID) throws { throw FailingAgentLedgerRepositoryError.forced }
    func clear(at timestamp: Date) throws { throw FailingAgentLedgerRepositoryError.forced }
}
