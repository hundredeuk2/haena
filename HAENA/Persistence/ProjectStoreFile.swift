import Foundation

/// On-disk schema for `JSONProjectRepository`. Wrapped in a versioned envelope — rather than
/// persisting a bare `[Project]` array — so a future format change has a documented version
/// to branch on instead of guessing from the shape of the JSON.
struct ProjectStoreFile: Codable, Equatable, Sendable {
    /// The schema version this build reads and writes. Bump this and add migration handling
    /// in `JSONProjectRepository` when the on-disk shape changes — not implemented in Phase 0.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]

    init(schemaVersion: Int = ProjectStoreFile.currentSchemaVersion, projects: [Project] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }
}
