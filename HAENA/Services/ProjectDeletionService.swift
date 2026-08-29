import Foundation

/// Internal failure reasons for project/meeting deletion. Kept separate from user-facing
/// Korean copy so the service stays presentation-agnostic and unit-testable.
enum ProjectDeletionError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    case repositoryFailure
}

/// Finite durability boundaries of a deletion, exposed only through dependency injection.
///
/// Production assembles a no-op observer, exactly as the transition-apply path does. A Debug-only
/// process smoke harness can terminate the app at one of these boundaries without putting a crash
/// switch anywhere near the persistence repositories.
///
/// The two "sidecar cleaned" cases sit at different places for a real reason: a meeting deletion
/// clears its intent in a second write after the sweep, so there is an observable moment between
/// them, while a project deletion retires its intent inside the sweep's own write, so the moment
/// after it is already terminal for both stores and only the audio unlink remains.
enum MeetingDeletionCheckpoint: String, Equatable, Sendable {
    case meetingIntentStored = "meeting_after_intent"
    case meetingProjectSaved = "meeting_after_project"
    /// After the sidecar sweep, before the intent is cleared.
    case meetingSidecarCleaned = "meeting_after_sidecar"
    case projectIntentStored = "project_after_intent"
    case projectAggregateDeleted = "project_after_aggregate"
    /// After the sweep-and-retire write, before the audio unlink.
    case projectSidecarCleaned = "project_after_sidecar"
}

/// Deletes a whole `Project` aggregate, or one `Meeting` (and everything derived from it) out
/// of a project, keeping model mutation and repository access out of the View layer.
///
/// **Audio policy:** deleting a meeting or a project also deletes the app's stored copy of any
/// audio those meetings were imported from. The alternative — keeping the file after its only
/// reference is gone — would quietly accumulate unreachable recordings of the user's meetings in
/// Application Support with no way to find or remove them from inside the app.
///
/// The record is always removed first and the file second: if the unlink fails, the result is an
/// orphaned file rather than a stored meeting pointing at audio that no longer exists. Deletion
/// is a plain unlink, not a secure erase.
///
/// `now` is injected (defaulting to `Date.init`) so tests can pin the resulting
/// `Project.updatedAt` to a fixed value instead of depending on wall-clock time.
struct ProjectDeletionService: Sendable {
    let repository: any ProjectRepository
    /// Nil in contexts that never import audio (and in tests that do not exercise it); stored
    /// audio is then simply not touched.
    let assetStore: AudioAssetStore?
    /// Nil where continuity is not configured, exactly like `assetStore`. The sidecar is then not
    /// touched — which is correct, because without continuity there is nothing in it to orphan.
    let transitions: (any WorkStateTransitionRepository)?
    let now: @Sendable () -> Date
    /// No-op in production. See `MeetingDeletionCheckpoint`.
    let didReachCheckpoint: @Sendable (MeetingDeletionCheckpoint) -> Void

    init(
        repository: any ProjectRepository,
        assetStore: AudioAssetStore? = nil,
        transitions: (any WorkStateTransitionRepository)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        didReachCheckpoint: @escaping @Sendable (MeetingDeletionCheckpoint) -> Void = { _ in }
    ) {
        self.repository = repository
        self.assetStore = assetStore
        self.transitions = transitions
        self.now = now
        self.didReachCheckpoint = didReachCheckpoint
    }

    /// Deletes an entire project — meetings, decisions, action items, open questions, and
    /// agenda items all go with it, since they live nested inside the `Project` aggregate.
    /// Every meeting's stored audio goes too.
    func deleteProject(id: UUID) async throws {
        guard let project = try await existingProject(id: id) else {
            throw ProjectDeletionError.projectNotFound
        }

        // Same shape as `deleteMeeting`, one scope up: the intent is written before either store
        // changes, so an interruption leaves a state a relaunch can finish rather than guess at.
        let intent = ProjectDeletionIntent(projectID: id, requestedAt: now())
        if let transitions {
            do {
                try await transitions.recordProjectDeletionIntent(intent)
            } catch {
                // Nothing removed yet, so the project is still whole. A failure the user can retry.
                throw ProjectDeletionError.repositoryFailure
            }
            didReachCheckpoint(.projectIntentStored)
        }

        do {
            try await repository.delete(id: id)
        } catch {
            throw ProjectDeletionError.repositoryFailure
        }
        didReachCheckpoint(.projectAggregateDeleted)

        try await finishProjectDeletion(intent)
        didReachCheckpoint(.projectSidecarCleaned)

        removeStoredAudio(for: project.meetings)
    }

    /// Removes one meeting from a project, along with every Decision/ActionItem/OpenQuestion
    /// whose `meetingID` points at it and every AgendaItem whose `sourceMeetingID` points at
    /// it — no orphaned references to the deleted meeting are left behind. Their embedded
    /// `EvidenceReference` values go with them automatically, since evidence lives inside
    /// those objects rather than as a separate top-level collection.
    ///
    /// Since the transition sidecar became part of this, the deletion spans two stores and can be
    /// interrupted between them. The order below exists so that every interruption leaves a state a
    /// relaunch can finish rather than one it has to guess at:
    ///
    /// 1. write the intent — the only step that must survive to make the rest recoverable
    /// 2. save the Project without the meeting (one atomic write, as before)
    /// 3. clean the sidecar (one atomic write)
    /// 4. drop the intent
    /// 5. unlink audio
    ///
    /// Audio stays last for the reason it always has: an orphaned file is a better outcome than a
    /// stored meeting pointing at audio that is already gone.
    @discardableResult
    func deleteMeeting(meetingID: UUID, fromProjectID projectID: UUID) async throws -> Project {
        guard var project = try await existingProject(id: projectID) else {
            throw ProjectDeletionError.projectNotFound
        }
        guard let meeting = project.meetings.first(where: { $0.id == meetingID }) else {
            throw ProjectDeletionError.meetingNotFound
        }

        // Captured before the removal: once the Project is saved it can no longer say which objects
        // belonged to this meeting, and the sidecar closure hangs off exactly these ids.
        let intent = MeetingDeletionIntent(
            projectID: projectID,
            meetingID: meetingID,
            removedWorkStateIDs: Self.derivedWorkStateIDs(of: meetingID, in: project),
            requestedAt: now()
        )
        if let transitions {
            do {
                try await transitions.recordMeetingDeletionIntent(intent)
            } catch {
                // Nothing has been removed yet, so failing here leaves the meeting intact rather
                // than half-deleted. Reported as a failure the user can retry.
                throw ProjectDeletionError.repositoryFailure
            }
            didReachCheckpoint(.meetingIntentStored)
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
        didReachCheckpoint(.meetingProjectSaved)

        try await finishMeetingDeletion(intent)

        removeStoredAudio(for: [meeting])

        return project
    }

    /// Finishes deletions that were authorized but interrupted, at launch.
    ///
    /// Every step it runs is a no-op when it has already happened, so a deletion interrupted twice
    /// converges on the same file as one that was never interrupted. Failures are left for the next
    /// launch rather than thrown: a stuck recovery must not be able to stop the app from starting.
    func recoverInterruptedMeetingDeletions() async {
        guard let transitions,
              let pending = try? await transitions.pendingMeetingDeletionIntents() else {
            return
        }
        for intent in pending {
            // Step 2 may not have happened. Re-running it is safe — `removeAll` over a meeting that
            // is already gone removes nothing — and it is what makes a crash between the intent and
            // the Project save recoverable at all.
            if var project = try? await repository.project(id: intent.projectID),
               project.meetings.contains(where: { $0.id == intent.meetingID }) {
                project.meetings.removeAll { $0.id == intent.meetingID }
                project.decisions.removeAll { $0.meetingID == intent.meetingID }
                project.actionItems.removeAll { $0.meetingID == intent.meetingID }
                project.openQuestions.removeAll { $0.meetingID == intent.meetingID }
                project.nextAgenda.removeAll { $0.sourceMeetingID == intent.meetingID }
                project.updatedAt = now()
                guard (try? await repository.save(project)) != nil else { continue }
            }
            try? await finishMeetingDeletion(intent)
        }
    }

    /// Finishes project deletions that were authorized but interrupted, at launch.
    ///
    /// The aggregate delete is re-run first because it may not have happened, and it is a no-op
    /// when it has: removing a key that is already gone changes nothing. Failures are left for the
    /// next launch rather than thrown, for the same reason as the meeting path — a stuck recovery
    /// must not be able to stop the app from starting.
    func recoverInterruptedProjectDeletions() async {
        guard let transitions,
              let pending = try? await transitions.pendingProjectDeletionIntents() else {
            return
        }
        for intent in pending {
            guard (try? await repository.delete(id: intent.projectID)) != nil else { continue }
            try? await finishProjectDeletion(intent)
        }
    }

    /// The sidecar half, shared by the live path and recovery so they cannot drift apart. The sweep
    /// and the retirement of the intent are one write inside the repository, so there is no state
    /// where the rows are gone and the receipt still says they are not.
    private func finishProjectDeletion(_ intent: ProjectDeletionIntent) async throws {
        guard let transitions else { return }
        do {
            try await transitions.applyProjectDeletion(intent)
        } catch {
            // The aggregate is already deleted and is the authority. The intent stays on disk, so
            // the next launch finishes the sidecar instead of leaving its rows there forever.
            throw ProjectDeletionError.repositoryFailure
        }
    }

    /// Steps 3 and 4, shared by the live path and recovery so they cannot drift apart.
    private func finishMeetingDeletion(_ intent: MeetingDeletionIntent) async throws {
        guard let transitions else { return }
        do {
            try await transitions.applyMeetingDeletion(intent)
            didReachCheckpoint(.meetingSidecarCleaned)
            try await transitions.clearMeetingDeletionIntent(intent)
        } catch {
            // The Project is already saved and is the authority. The intent stays on disk, so the
            // next launch finishes the sidecar instead of leaving orphans there forever.
            throw ProjectDeletionError.repositoryFailure
        }
    }

    /// The Work State this meeting produced, by the same rules the removal below uses. Identity
    /// only — no titles, no evidence — because these ids end up in a durable deletion receipt.
    private static func derivedWorkStateIDs(of meetingID: UUID, in project: Project) -> [UUID] {
        project.decisions.filter { $0.meetingID == meetingID }.map(\.id)
            + project.actionItems.filter { $0.meetingID == meetingID }.map(\.id)
            + project.openQuestions.filter { $0.meetingID == meetingID }.map(\.id)
            + project.nextAgenda.filter { $0.sourceMeetingID == meetingID }.map(\.id)
    }

    private func removeStoredAudio(for meetings: [Meeting]) {
        guard let assetStore else {
            return
        }
        for asset in meetings.compactMap(\.audioAsset) {
            assetStore.remove(asset)
        }
    }

    private func existingProject(id: UUID) async throws -> Project? {
        do {
            return try await repository.project(id: id)
        } catch {
            throw ProjectDeletionError.repositoryFailure
        }
    }
}
