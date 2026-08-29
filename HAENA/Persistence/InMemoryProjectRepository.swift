import Foundation

/// Test/dev-only `ProjectRepository` backed by an in-memory dictionary. An `actor` serializes
/// all access, so concurrent saves/reads/deletes from multiple tasks cannot race or corrupt state.
actor InMemoryProjectRepository: WorkStateTransitionProjectRepository {
    private var storage: [UUID: Project] = [:]
    private var transitionApplyMarkers: [String: WorkStateTransitionApplyMarker] = [:]

    init(projects: [Project] = []) {
        storage = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    func save(_ project: Project) throws {
        storage[project.id] = project
    }

    func save(
        _ project: Project,
        recording marker: WorkStateTransitionApplyMarker
    ) throws {
        guard project.id == marker.projectID else {
            throw JSONRepositoryError.encodingFailed(
                underlying: "transition apply marker project mismatch"
            )
        }
        storage[project.id] = project
        transitionApplyMarkers[marker.storageKey] = marker
    }

    func transitionApplyMarker(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind
    ) -> WorkStateTransitionApplyMarker? {
        transitionApplyMarkers[
            WorkStateTransitionApplyMarker(
                projectID: projectID,
                operationID: operationID,
                operationKind: operationKind,
                intentHash: "",
                appliedAt: .distantPast
            ).storageKey
        ]
    }

    func project(id: UUID) throws -> Project? {
        storage[id]
    }

    func allProjects() throws -> [Project] {
        Array(storage.values)
    }

    func delete(id: UUID) throws {
        storage.removeValue(forKey: id)
        transitionApplyMarkers = transitionApplyMarkers.filter { $0.value.projectID != id }
    }
}
