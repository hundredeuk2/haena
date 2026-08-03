import Foundation

/// Internal failure reasons for project/meeting deletion. Kept separate from user-facing
/// Korean copy so the service stays presentation-agnostic and unit-testable.
enum ProjectDeletionError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    case repositoryFailure
}

/// Deletes a whole `Project` aggregate, or one `Meeting` (and everything derived from it) out
/// of a project, keeping model mutation and repository access out of the View layer.
///
/// `now` is injected (defaulting to `Date.init`) so tests can pin the resulting
/// `Project.updatedAt` to a fixed value instead of depending on wall-clock time.
struct ProjectDeletionService: Sendable {
    let repository: any ProjectRepository
    let now: @Sendable () -> Date

    init(
        repository: any ProjectRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    /// Deletes an entire project — meetings, decisions, action items, open questions, and
    /// agenda items all go with it, since they live nested inside the `Project` aggregate.
    func deleteProject(id: UUID) async throws {
        guard try await existingProject(id: id) != nil else {
            throw ProjectDeletionError.projectNotFound
        }
        do {
            try await repository.delete(id: id)
        } catch {
            throw ProjectDeletionError.repositoryFailure
        }
    }

    /// Removes one meeting from a project, along with every Decision/ActionItem/OpenQuestion
    /// whose `meetingID` points at it and every AgendaItem whose `sourceMeetingID` points at
    /// it — no orphaned references to the deleted meeting are left behind. Their embedded
    /// `EvidenceReference` values go with them automatically, since evidence lives inside
    /// those objects rather than as a separate top-level collection.
    @discardableResult
    func deleteMeeting(meetingID: UUID, fromProjectID projectID: UUID) async throws -> Project {
        guard var project = try await existingProject(id: projectID) else {
            throw ProjectDeletionError.projectNotFound
        }
        guard project.meetings.contains(where: { $0.id == meetingID }) else {
            throw ProjectDeletionError.meetingNotFound
        }

        project.meetings.removeAll { $0.id == meetingID }
        project.decisions.removeAll { $0.meetingID == meetingID }
        project.actionItems.removeAll { $0.meetingID == meetingID }
        project.openQuestions.removeAll { $0.meetingID == meetingID }
        project.nextAgenda.removeAll { $0.sourceMeetingID == meetingID }
        project.updatedAt = now()

        do {
            try await repository.save(project)
        } catch {
            throw ProjectDeletionError.repositoryFailure
        }

        return project
    }

    private func existingProject(id: UUID) async throws -> Project? {
        do {
            return try await repository.project(id: id)
        } catch {
            throw ProjectDeletionError.repositoryFailure
        }
    }
}
