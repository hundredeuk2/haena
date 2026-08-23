import Foundation

/// Test/dev-only `ProjectRepository` backed by an in-memory dictionary. An `actor` serializes
/// all access, so concurrent saves/reads/deletes from multiple tasks cannot race or corrupt state.
actor InMemoryProjectRepository: ProjectRepository {
    private var storage: [UUID: Project] = [:]

    init(projects: [Project] = []) {
        storage = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    func save(_ project: Project) throws {
        storage[project.id] = project
    }

    func project(id: UUID) throws -> Project? {
        storage[id]
    }

    func allProjects() throws -> [Project] {
        Array(storage.values)
    }

    func delete(id: UUID) throws {
        storage.removeValue(forKey: id)
    }
}
