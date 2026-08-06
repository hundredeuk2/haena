import Foundation

/// A file that has passed every check and may now be copied and uploaded.
///
/// Exists so the rest of the flow cannot accidentally operate on an unvalidated URL: services
/// take this type, and the only way to obtain one is through `AudioFileValidator`.
struct ValidatedAudioFile: Equatable, Sendable {
    let url: URL
    let fileName: String
    let byteSize: Int
}

/// Why a chosen file cannot be transcribed. Carries the concrete numbers where the user needs
/// them (size, limit, extension) so the UI can explain the problem rather than say "failed".
enum AudioFileValidationError: Error, Equatable, Sendable {
    case fileNotFound
    case notReadable
    case unsupportedFormat(fileExtension: String)
    case emptyFile
    case fileTooLarge(byteSize: Int, limit: Int)
}

/// Rejects files the provider would reject anyway, before anything is copied or uploaded.
///
/// Runs entirely locally and before the network: a file over the provider's ceiling is a
/// guaranteed failure, and finding that out after a multi-megabyte upload wastes the user's time
/// and bandwidth. Nothing here converts, compresses, or splits audio — an unsupported file is
/// reported, not silently transformed into a supported one.
struct AudioFileValidator: Sendable {
    /// Exactly the container formats OpenAI's transcription endpoint accepts.
    static let supportedExtensions: Set<String> = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]

    /// OpenAI's published 25 MB upload ceiling, in bytes.
    static let maximumFileBytes = 25 * 1024 * 1024

    private let maximumFileBytes: Int

    /// `FileManager.default` is used directly rather than injected: it is documented as safe to
    /// use from multiple threads, and injecting it would make this type non-`Sendable` for no
    /// test benefit — tests write real files into a temporary directory.
    private var fileManager: FileManager { .default }

    init(maximumFileBytes: Int = AudioFileValidator.maximumFileBytes) {
        self.maximumFileBytes = maximumFileBytes
    }

    /// Checks are ordered cheapest-and-most-fundamental first, so the error the user sees names
    /// the *first* real problem rather than a downstream symptom of it.
    func validate(_ url: URL) throws -> ValidatedAudioFile {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AudioFileValidationError.fileNotFound
        }

        let fileExtension = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw AudioFileValidationError.unsupportedFormat(fileExtension: fileExtension)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw AudioFileValidationError.notReadable
        }

        // Attribute read failure is reported as unreadable rather than as a zero-byte file:
        // "we could not read this" is true and actionable, "it is empty" would be a guess.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw AudioFileValidationError.notReadable
        }
        guard let byteSize = (attributes[.size] as? NSNumber)?.intValue else {
            throw AudioFileValidationError.notReadable
        }

        guard byteSize > 0 else {
            throw AudioFileValidationError.emptyFile
        }
        guard byteSize <= maximumFileBytes else {
            throw AudioFileValidationError.fileTooLarge(byteSize: byteSize, limit: maximumFileBytes)
        }

        return ValidatedAudioFile(url: url, fileName: url.lastPathComponent, byteSize: byteSize)
    }
}
