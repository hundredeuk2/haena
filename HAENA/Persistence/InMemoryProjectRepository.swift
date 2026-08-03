import Foundation

/// Test/dev-only `ProjectRepository` backed by an in-memory dictionary. An `actor` serializes
/// all access, so concurrent saves/reads/deletes from multiple tasks cannot race or corrupt state.
actor InMemoryProjectRepository: ProjectRepository {
    private var storage: [UUID: Project] = [:]

    init() {}

    func save(_ project: Project) {
        storage[project.id] = project
    }

    func project(id: UUID) -> Project? {
        storage[id]
    }

    func allProjects() -> [Project] {
        Array(storage.values)
    }

    func delete(id: UUID) {
        storage.removeValue(forKey: id)
    }
}
