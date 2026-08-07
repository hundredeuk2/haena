import Foundation

enum AudioAssetStoreError: Error, Equatable, Sendable {
    case directoryCreationFailed
    case copyFailed
}

/// Owns the app's private copies of imported audio.
///
/// Copying happens *before* the network call, so the original stays untouched and a provider
/// failure leaves a complete local file the user can retry from. Stored names are UUID-based, so
/// importing two different files both called `meeting.m4a` can never overwrite one another.
struct AudioAssetStore: Sendable {
    private let directoryURL: URL

    /// `FileManager.default` is used directly rather than injected: it is documented as safe to
    /// use from multiple threads, and injecting it would make this type non-`Sendable` for no
    /// test benefit — tests vary the directory, which *is* injected.
    private var fileManager: FileManager { .default }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// `Application Support/com.haena.HAENA/Audio/`, alongside `projects.json`. Never Documents
    /// or Desktop. Non-throwing for the same reason as `JSONProjectRepository.defaultFileURL()`:
    /// this runs at app-assembly time, where a path computation must not be able to crash launch.
    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.haena.HAENA", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
    }

    func url(for asset: AudioAsset) -> URL {
        directoryURL.appendingPathComponent(asset.storedFileName)
    }

    /// Copies the validated file in and returns the asset describing the copy.
    ///
    /// The extension is preserved because the provider infers the container format from the
    /// multipart filename; the stem is replaced by a UUID because the user's own file name is
    /// neither unique nor guaranteed to be a safe path component.
    func store(
        _ file: ValidatedAudioFile,
        id: UUID,
        importedAt: Date
    ) throws -> AudioAsset {
        try ensureDirectoryExists()

        let fileExtension = file.url.pathExtension.lowercased()
        let storedFileName = fileExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(fileExtension)"
        let destination = directoryURL.appendingPathComponent(storedFileName)

        do {
            try fileManager.copyItem(at: file.url, to: destination)
        } catch {
            throw AudioAssetStoreError.copyFailed
        }

        // Best-effort, matching `JSONProjectRepository`: the copy already succeeded, and failing
        // the import over a chmod hiccup would be a worse outcome than the default umask.
        _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        return AudioAsset(
            id: id,
            storedFileName: storedFileName,
            originalFileName: file.fileName,
            byteSize: file.byteSize,
            importedAt: importedAt
        )
    }

    /// Deletes the app's copy. Best-effort by design: this is called while removing a meeting or
    /// project, and a file that is already gone — or that cannot be removed — must not abort a
    /// deletion the user asked for and leave the record half-removed.
    ///
    /// This is a plain delete, not a secure erase; overwriting before unlinking is out of scope
    /// for Phase 0.
    func remove(_ asset: AudioAsset) {
        try? fileManager.removeItem(at: url(for: asset))
    }

    private func ensureDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw AudioAssetStoreError.directoryCreationFailed
        }
    }
}
