import Foundation

/// Where an in-progress recording is written before anyone decides to keep it.
///
/// Deliberately *not* `AudioAssetStore`: that directory holds audio a meeting refers to, and a
/// recording is not that until the user has named it and transcription has run. Keeping the two
/// apart means an abandoned recording can never be mistaken for a meeting's audio, and cleanup
/// here can be unconditional.
///
/// File names are UUIDs. A recording's name must not leak the meeting title, the project, or the
/// user — a temporary directory is readable by anything running as this user, and a predictable
/// name would also let two recordings collide.
struct RecordingScratchStore: Sendable {
    let directoryURL: URL

    private var fileManager: FileManager { .default }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// A per-launch directory under the system temporary area. Non-throwing for the same reason as
    /// the other stores: this is computed at app-assembly time, where a path calculation must not
    /// be able to crash launch.
    static func defaultDirectoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.haena.HAENA", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    func makeDestination(id: UUID = UUID(), fileExtension: String) throws -> URL {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw MeetingAudioRecorderError.fileWriteFailed
        }
        return directoryURL.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    /// Best-effort by design: this runs on teardown paths — a cancelled recording, a closed sheet,
    /// a quitting app — where refusing to finish because a file was already gone would be worse
    /// than leaving one behind.
    func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// Clears everything left over. The entry point for app termination, and the reason a crashed
    /// session does not accumulate recordings forever.
    func removeAll() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}
