import Foundation

/// Read-only query layer over `ProjectRepository` for the project/meeting browser screens.
/// Keeps repository access and sort ordering out of View bodies without needing a full
/// ObservableObject/ViewModel — the browser view holds its own `@State` and calls this
/// stateless service directly, the same pattern `TextMeetingCaptureService` already uses.
struct ProjectBrowserQueryService: Sendable {
    let repository: any ProjectRepository

    /// Loads every stored project, always in the same deterministic order regardless of what
    /// order the repository itself returns them in.
    func loadProjects() async throws -> [Project] {
        let projects = try await repository.allProjects()
        return projects.sorted(by: Self.isOrderedBefore)
    }

    /// `updatedAt` descending, then `createdAt` descending, then UUID string ascending — a
    /// total order so the displayed list never depends on the repository's internal ordering.
    static func isOrderedBefore(_ lhs: Project, _ rhs: Project) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// `occurredAt` descending, then `createdAt` descending, then UUID string ascending.
    static func sortedMeetings(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt > rhs.occurredAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
