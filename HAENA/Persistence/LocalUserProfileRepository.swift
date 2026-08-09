import Foundation

/// On-disk shape for the local profile, in the same versioned-envelope style as
/// `ProjectStoreFile`.
///
/// A file of its own, beside `projects.json`, rather than a field inside it. Two reasons, both
/// about not putting the user's meeting data at risk for a name: `JSONProjectRepository` rewrites
/// the whole project file on every save, so a profile living in there would have to be threaded
/// through an actor that has no other reason to know about it — and one bug in that plumbing
/// silently erases either the profile or the projects. Separate files also mean **no schema change
/// at all** to the existing store: an install that predates this feature reads exactly as before,
/// finds no profile file, and reports "not set up" rather than failing to load.
struct LocalUserProfileStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Singular. One person uses this app; an array here would be the first line of an account
    /// system, which is explicitly not what this is.
    var profile: LocalUserProfile?

    init(
        schemaVersion: Int = LocalUserProfileStoreFile.currentSchemaVersion,
        profile: LocalUserProfile? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
    }
}

/// Storage boundary for the single local profile. Silent about the backing technology, matching
/// `ProjectRepository`.
protocol LocalUserProfileRepository: Sendable {
    /// Nil when the user has not set themselves up yet — a normal state, not an error.
    func profile() async throws -> LocalUserProfile?
    func save(_ profile: LocalUserProfile) async throws
}

/// The real store: one small JSON file next to the projects.
actor JSONLocalUserProfileRepository: LocalUserProfileRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: LocalUserProfile??

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// `Application Support/com.haena.HAENA/profile.json`, alongside `projects.json`. Non-throwing
    /// for the same reason as the project store's: this runs at app-assembly time, where a path
    /// computation must not be able to crash launch.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        JSONProjectRepository.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("profile.json")
    }

    func profile() throws -> LocalUserProfile? {
        if let cache {
            return cache
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            cache = .some(nil)
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw JSONRepositoryError.readFailed(underlying: String(describing: error))
        }

        let store: LocalUserProfileStoreFile
        do {
            store = try JSONDecoder().decode(LocalUserProfileStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }

        guard store.schemaVersion == LocalUserProfileStoreFile.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: LocalUserProfileStoreFile.currentSchemaVersion
            )
        }

        cache = .some(store.profile)
        return store.profile
    }

    func save(_ profile: LocalUserProfile) throws {
        try ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(LocalUserProfileStoreFile(profile: profile))
        } catch {
            throw JSONRepositoryError.encodingFailed(underlying: String(describing: error))
        }

        // Atomic temp-then-replace and owner-only permissions, exactly as the project store does.
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

        cache = .some(profile)
    }

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JSONRepositoryError.directoryCreationFailed(underlying: String(describing: error))
        }
    }
}

/// Test/dev-only store, matching `InMemoryProjectRepository`.
actor InMemoryLocalUserProfileRepository: LocalUserProfileRepository {
    private var stored: LocalUserProfile?

    init(profile: LocalUserProfile? = nil) {
        stored = profile
    }

    func profile() throws -> LocalUserProfile? {
        stored
    }

    func save(_ profile: LocalUserProfile) throws {
        stored = profile
    }
}
