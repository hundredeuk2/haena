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

enum WorkStateTransitionApplyOperationKind: String, Codable, Equatable, Sendable {
    case proposal
    case ambiguity
}

/// Privacy-safe receipt written in the same atomic envelope as the mutated Project.
///
/// The transition sidecar owns the user's verdict. This marker only proves that the Project
/// effect for one prepared intent reached durable storage, so recovery can finish the missing
/// sidecar write without replaying the mutation.
struct WorkStateTransitionApplyMarker: Codable, Equatable, Sendable {
    let projectID: UUID
    let operationID: UUID
    let operationKind: WorkStateTransitionApplyOperationKind
    let intentHash: String
    let appliedAt: Date

    var storageKey: String {
        "\(projectID.uuidString.lowercased())|\(operationKind.rawValue)|\(operationID.uuidString.lowercased())"
    }
}

/// Narrow Project persistence capability required only by transition review/apply.
protocol WorkStateTransitionProjectRepository: ProjectRepository {
    func save(
        _ project: Project,
        recording marker: WorkStateTransitionApplyMarker
    ) async throws
    func transitionApplyMarker(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind
    ) async throws -> WorkStateTransitionApplyMarker?
}
