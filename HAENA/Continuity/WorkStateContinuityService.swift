import Foundation

/// Why a transition run could not be completed. Deliberately separates "the project could not be
/// read" from "the transitions could not be stored", because the two have opposite implications:
/// the first means nothing was computed, the second means something was computed and then lost.
enum WorkStateContinuityError: Error, Equatable, Sendable {
    case projectNotFound
    case meetingNotFound
    /// Reading the project failed. No transition was generated.
    case projectRepositoryFailure
    /// The transitions were generated but could not be recorded. Approved work state is untouched.
    case transitionStoreFailure
}

/// Generates transition proposals for one meeting and records them — the whole of the Meeting
/// Continuity v0 write path.
///
/// The ordering here is the safety property, and it is worth stating plainly: this service reads a
/// `Project` and never writes one back. It holds a `ProjectRepository` solely to load the approved
/// snapshot, and there is no code path from here to `ProjectRepository.save`. Combined with the
/// transition store being a separate file, that makes "generating proposals cannot alter approved
/// work state" true by construction rather than by discipline — a reviewer can confirm it by
/// checking which calls exist, not by reasoning about when they run.
///
/// The user-approval step that turns a proposal into an actual state change is a follow-up task.
/// Nothing here approves anything: every proposal it stores is `.pendingReview`.
struct WorkStateContinuityService: Sendable {
    /// Read-only from this service's perspective. See the type's own note above.
    let projects: any ProjectRepository
    let transitions: any WorkStateTransitionRepository
    let now: @Sendable () -> Date

    init(
        projects: any ProjectRepository,
        transitions: any WorkStateTransitionRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projects = projects
        self.transitions = transitions
        self.now = now
    }

    /// Compares the project's approved state against one meeting's mapped output and records what
    /// changed.
    ///
    /// The structured inputs stay explicit parameters so the extraction producer can pass only
    /// locally validated, evidence-carrying claims. `completed`, `delayed`-by-deferral, and
    /// `resolved` never depend on this service parsing a phrase from the transcript.
    ///
    /// Returns the engine's full result. Proposals, ambiguity groups, and finite refusal records are
    /// persisted together so a later Manual Brief can explain the run after an app restart.
    @discardableResult
    func recordTransitions(
        forProject projectID: UUID,
        sourceMeetingID: UUID,
        incoming: ValidatedWorkState,
        progressSignals: [WorkStateProgressSignal] = [],
        resolutionLinks: [OpenQuestionResolutionLink] = [],
        derivedActionItemLinks: [DecisionDerivedActionItemLink] = [],
        decisionChangeLinks: [DecisionChangeLink] = []
    ) async throws -> WorkStateTransitionEngineResult {
        let loaded: Project?
        do {
            loaded = try await projects.project(id: projectID)
        } catch {
            throw WorkStateContinuityError.projectRepositoryFailure
        }
        guard let project = loaded else {
            throw WorkStateContinuityError.projectNotFound
        }

        // The meeting must belong to this project. Taking `occurredAt` from stored state rather than
        // from a parameter is what keeps lateness a fact about the record: a caller cannot make a
        // task look overdue by passing a later date than the meeting actually had.
        guard let meeting = project.meetings.first(where: { $0.id == sourceMeetingID }) else {
            throw WorkStateContinuityError.meetingNotFound
        }

        let recordedAt = now()
        let result = WorkStateTransitionEngine.generate(
            WorkStateTransitionEngineInput(
                projectID: projectID,
                sourceMeetingID: sourceMeetingID,
                occurredAt: meeting.occurredAt,
                prior: ApprovedWorkStateSnapshot(project: project),
                incoming: incoming,
                progressSignals: progressSignals,
                resolutionLinks: resolutionLinks,
                derivedActionItemLinks: derivedActionItemLinks,
                decisionChangeLinks: decisionChangeLinks
            ),
            now: recordedAt
        )

        let run = WorkStateContinuityRunIdentity(
            projectID: projectID,
            sourceMeetingID: sourceMeetingID
        )
        let refusalRecords = result.refusals.map {
            WorkStateTransitionRefusalRecord(run: run, refusal: $0, createdAt: recordedAt)
        }

        // A failed write is surfaced as a failure, never as a successful run whose results happen to
        // be missing next launch. The engine's output is discarded on this path rather than returned
        // alongside the error, so a caller cannot mistake computed-but-unstored for recorded.
        do {
            try await transitions.upsert(
                proposals: result.proposals,
                ambiguousMatchGroups: result.ambiguousMatchGroups,
                refusals: refusalRecords
            )
        } catch {
            throw WorkStateContinuityError.transitionStoreFailure
        }

        return result
    }
}
