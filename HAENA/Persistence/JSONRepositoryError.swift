import Foundation

/// Explicit failure reasons for `JSONProjectRepository`, so callers can distinguish a missing
/// directory from a corrupt file from a schema mismatch instead of catching one opaque error.
///
/// Underlying causes are captured as `String` descriptions rather than the original `Error` —
/// an arbitrary `Error` existential isn't guaranteed `Sendable`, and these strings exist purely
/// for debugging (logs, test assertions), never for display, so losing the original error's
/// type is an acceptable trade for a Sendable-safe, warning-free error type.
enum JSONRepositoryError: Error, Sendable {
    case directoryCreationFailed(underlying: String)
    case readFailed(underlying: String)
    case decodingFailed(underlying: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case encodingFailed(underlying: String)
    case writeFailed(underlying: String)
}
