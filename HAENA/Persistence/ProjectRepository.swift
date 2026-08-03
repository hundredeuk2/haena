import Foundation

/// Storage boundary for `Project` aggregates. Deliberately silent on the backing technology
/// (in-memory, JSON file, SwiftData, ...) so a concrete implementation can be swapped later
/// without touching anything that depends on this protocol.
protocol ProjectRepository: Sendable {
    func save(_ project: Project) async
    func project(id: UUID) async -> Project?
    func allProjects() async -> [Project]
    func delete(id: UUID) async
}
