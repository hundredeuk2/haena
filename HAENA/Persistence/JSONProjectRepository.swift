import Foundation

/// `ProjectRepository` backed by a single JSON file on disk, guarded by an `actor` so every
/// read/write is serialized (no data races within one instance). Concurrent writers across
/// multiple *processes* or multiple repository instances pointed at the same file are out of
/// scope for Phase 0 — see `AI Work OS Product Direction` local-first assumptions.
///
/// State is loaded lazily on first access and cached in memory afterward; every mutation is
/// written back to disk immediately via an atomic temp-file-then-replace, so the file on disk
/// never reflects a half-written state.
actor JSONProjectRepository: ProjectRepository {
    static let supportedSchemaVersion = ProjectStoreFile.currentSchemaVersion

    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: [UUID: Project]?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// The standard per-user location for HAE.NA's persisted project data:
    /// `Application Support/com.haena.HAENA/projects.json`. Never Documents or Desktop.
    ///
    /// Deliberately non-throwing: this is called once at app-assembly time (`HAENAApp`), and
    /// app startup must never crash over a path computation. `FileManager.urls(for:in:)` only
    /// fails to return an entry in exotic sandboxing situations that don't apply here; the
    /// home-directory fallback keeps this total even then.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.haena.HAENA", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    func save(_ project: Project) async throws {
        var projects = try loadIfNeeded()
        projects[project.id] = project
        try persist(projects)
        cache = projects
    }

    func project(id: UUID) async throws -> Project? {
        let projects = try loadIfNeeded()
        return projects[id]
    }

    func allProjects() async throws -> [Project] {
        let projects = try loadIfNeeded()
        return sorted(projects)
    }

    func delete(id: UUID) async throws {
        var projects = try loadIfNeeded()
        projects.removeValue(forKey: id)
        try persist(projects)
        cache = projects
    }

    // MARK: - Loading

    private func loadIfNeeded() throws -> [UUID: Project] {
        if let cache {
            return cache
        }

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

        let store: ProjectStoreFile
        do {
            store = try JSONDecoder().decode(ProjectStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }

        guard store.schemaVersion == Self.supportedSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }

        var projects: [UUID: Project] = [:]
        for project in store.projects {
            projects[project.id] = project
        }
        cache = projects
        return projects
    }

    // MARK: - Persisting

    private func persist(_ projects: [UUID: Project]) throws {
        try ensureDirectoryExists()

        let store = ProjectStoreFile(projects: sorted(projects))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(store)
        } catch {
            throw JSONRepositoryError.encodingFailed(underlying: String(describing: error))
        }

        let temporaryURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }

        // Best-effort: restrict the file to the current user. Not treated as a fatal save
        // failure — the save already succeeded from the user's perspective, and refusing to
        // persist their meeting notes over an unrelated chmod hiccup would be a worse outcome
        // than a file left at the (already restrictive-by-default) process umask permissions.
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

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)

        // A regular file already occupying the directory's path is just as much a directory
        // creation failure as `mkdir` refusing outright — fall through to `createDirectory`
        // either way so both cases produce the same explicit, typed error.
        if exists && isDirectory.boolValue {
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JSONRepositoryError.directoryCreationFailed(underlying: String(describing: error))
        }
    }

    /// createdAt ascending: unlike `updatedAt`, `createdAt` never changes after a project is
    /// made, so list order stays stable across edits instead of reshuffling on every save.
    private func sorted(_ projects: [UUID: Project]) -> [Project] {
        projects.values.sorted { $0.createdAt < $1.createdAt }
    }
}
