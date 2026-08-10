import Foundation

protocol ActionItemReminderRepository: Sendable {
    func reminder(for actionItemID: UUID) async throws -> ActionItemReminder?
    func allReminders() async throws -> [ActionItemReminder]
    func save(_ reminder: ActionItemReminder) async throws
}

actor JSONActionItemReminderRepository: ActionItemReminderRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: [UUID: ActionItemReminder]?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        JSONProjectRepository.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-jobs.json")
    }

    func reminder(for actionItemID: UUID) throws -> ActionItemReminder? {
        try loadIfNeeded()[actionItemID]
    }

    func allReminders() throws -> [ActionItemReminder] {
        try loadIfNeeded().values.sorted { lhs, rhs in
            if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
            return lhs.actionItemID.uuidString < rhs.actionItemID.uuidString
        }
    }

    /// Upsert by ActionItem rather than by job id. This is the storage-level guarantee that one
    /// task can never accumulate two active reminder jobs.
    func save(_ reminder: ActionItemReminder) throws {
        var reminders = try loadIfNeeded()
        reminders[reminder.actionItemID] = reminder
        try persist(reminders)
        cache = reminders
    }

    private func loadIfNeeded() throws -> [UUID: ActionItemReminder] {
        if let cache { return cache }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return [:]
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw JSONRepositoryError.readFailed(underlying: String(describing: error))
        }

        let store: ActionItemReminderStoreFile
        do {
            store = try JSONDecoder().decode(ActionItemReminderStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }
        guard store.schemaVersion == ActionItemReminderStoreFile.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: ActionItemReminderStoreFile.currentSchemaVersion
            )
        }

        var reminders: [UUID: ActionItemReminder] = [:]
        for reminder in store.reminders {
            reminders[reminder.actionItemID] = reminder
        }
        cache = reminders
        return reminders
    }

    private func persist(_ reminders: [UUID: ActionItemReminder]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JSONRepositoryError.directoryCreationFailed(underlying: String(describing: error))
        }

        let ordered = reminders.values.sorted { $0.actionItemID.uuidString < $1.actionItemID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(ActionItemReminderStoreFile(reminders: ordered))
        } catch {
            throw JSONRepositoryError.encodingFailed(underlying: String(describing: error))
        }

        let temporaryURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }
        _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }
    }
}

actor InMemoryActionItemReminderRepository: ActionItemReminderRepository {
    private var reminders: [UUID: ActionItemReminder]
    private let saveError: Error?

    init(reminders: [ActionItemReminder] = [], saveError: Error? = nil) {
        self.reminders = Dictionary(uniqueKeysWithValues: reminders.map { ($0.actionItemID, $0) })
        self.saveError = saveError
    }

    func reminder(for actionItemID: UUID) -> ActionItemReminder? {
        reminders[actionItemID]
    }

    func allReminders() -> [ActionItemReminder] {
        reminders.values.sorted { $0.actionItemID.uuidString < $1.actionItemID.uuidString }
    }

    func save(_ reminder: ActionItemReminder) throws {
        if let saveError { throw saveError }
        reminders[reminder.actionItemID] = reminder
    }
}
