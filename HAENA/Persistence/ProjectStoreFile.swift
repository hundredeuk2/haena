import Foundation

/// On-disk schema for `JSONProjectRepository`. Wrapped in a versioned envelope — rather than
/// persisting a bare `[Project]` array — so a future format change has a documented version
/// to branch on instead of guessing from the shape of the JSON.
struct ProjectStoreFile: Codable, Equatable, Sendable {
    /// Schema 2 adds privacy-safe transition apply markers. Missing markers decode as empty so
    /// schema 1 Project aggregates remain readable without a separate migration pass.
    static let currentSchemaVersion = 2
    static let readableSchemaVersions: Set<Int> = [1, 2]

    var schemaVersion: Int
    var projects: [Project]
    var transitionApplyMarkers: [WorkStateTransitionApplyMarker]

    init(
        schemaVersion: Int = ProjectStoreFile.currentSchemaVersion,
        projects: [Project] = [],
        transitionApplyMarkers: [WorkStateTransitionApplyMarker] = []
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.transitionApplyMarkers = transitionApplyMarkers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, transitionApplyMarkers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decode([Project].self, forKey: .projects)
        transitionApplyMarkers = try container.decodeIfPresent(
            [WorkStateTransitionApplyMarker].self,
            forKey: .transitionApplyMarkers
        ) ?? []
    }
}
