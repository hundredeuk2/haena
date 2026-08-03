import Foundation

/// Storage boundary for `Project` aggregates. Deliberately silent on the backing technology
/// (in-memory, JSON file, SwiftData, ...) so a concrete implementation can be swapped later
/// without touching anything that depends on this protocol.
protocol ProjectRepository: Sendable {
    func save(_ project: Project) async throws
    func project(id: UUID) async throws -> Project?
    func allProjects() async throws -> [Project]
    func delete(id: UUID) async throws
}
