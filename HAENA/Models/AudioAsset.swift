import Foundation

/// The app's own copy of an imported audio file, recorded on the `Meeting` it produced.
///
/// `storedFileName` is a bare file name, never an absolute path: the Application Support
/// container can move between OS versions and machines, so a stored absolute URL would break
/// while a name resolved against the current container keeps working. `originalFileName` is kept
/// only to show the user which file this came from — it is never used to locate anything.
struct AudioAsset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let storedFileName: String
    let originalFileName: String
    let byteSize: Int
    let importedAt: Date
}
