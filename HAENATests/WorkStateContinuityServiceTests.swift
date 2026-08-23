import XCTest
@testable import HAENA

/// The write path: read approved state, generate transitions, record them — and nothing else.
///
/// The engine's own rules are covered by `WorkStateTransitionEngineTests` and the scenario suite.
/// What is only testable here is the wiring: that this service reads a project without ever writing
/// one back, that lateness is judged against the *stored* meeting rather than a caller-supplied
/// date, and that a failed store surfaces as a failure instead of a run whose results quietly went
/// missing.
final class WorkStateContinuityServiceTests: XCTestCase {

    private typealias Fixtures = WorkStateTransitionFixtures

    private struct ProjectStoreUnavailable: Error {}
    private struct TransitionStoreUnavailable: Error {}

    /// Fails every read, to prove a project that cannot be loaded is reported as such rather than
    /// treated as a project with no prior state (which would turn every item into a `new`).
    private struct FailingProjectRepository: ProjectRepository {
        func save(_ project: Project) async throws { throw ProjectStoreUnavailable() }
        func project(id: UUID) async throws -> Project? { throw ProjectStoreUnavailable() }
        func allProjects() async throws -> [Project] { throw ProjectStoreUnavailable() }
        func delete(id: UUID) async throws { throw ProjectStoreUnavailable() }
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    /// Long after both the meeting and every fixture due date.
    private let distantFuture = Date(timeIntervalSince1970: 4_000_000_000)

    /// The representative project carries no meetings, but this service reads `occurredAt` from the
    /// stored meeting — so one has to exist. A task due *after* the meeting but *before* the distant
    /// clock is added here: it is the only way to tell which of the two the engine actually used.
    private func projectWithSourceMeeting() -> Project {
        var project = Fixtures.representativeProject()
        project.meetings = [
            Meeting(
                id: Fixtures.sourceMeetingID,
                projectID: Fixtures.projectID,
                title: "Weekly sync",
                occurredAt: Fixtures.occurredAt,
                sourceType: .pastedText,
                participants: [],
                transcriptSegments: [],
                createdAt: Fixtures.priorCreatedAt
            )
        ]
        project.actionItems.append(
            Fixtures.approvedActionItem(
                id: Fixtures.uuid(950),
                title: Fixtures.anotherActionItemTitle,
                dueDate: Fixtures.futureDueDate
            )
        )
        return project
    }

    private func service(
        project: Project?,
        transitions: any WorkStateTransitionRepository,
        now: Date? = nil
    ) async throws -> WorkStateContinuityService {
        let projects = InMemoryProjectRepository()
        if let project {
            try await projects.save(project)
        }
        let clock = now ?? self.now
        return WorkStateContinuityService(
            projects: projects,
            transitions: transitions,
            now: { clock }
        )
    }

    // MARK: - The happy path

    func testRecordingTransitionsStoresExactlyWhatTheEngineProduced() async throws {
        let project = projectWithSourceMeeting()
        let transitions = InMemoryWorkStateTransitionRepository()
        let service = try await service(project: project, transitions: transitions)

        let result = try await service.recordTransitions(
            forProject: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            incoming: Fixtures.representativeInput().incoming
        )

        XCTAssertFalse(result.proposals.isEmpty)
        let stored = await transitions.proposals(forProject: project.id)
        XCTAssertEqual(stored, result.proposals)
        XCTAssertTrue(
            stored.allSatisfy { $0.reviewStatus == .pendingReview },
            "This service approves nothing; approval is a separate, user-driven step."
        )
    }

    /// Running the same meeting through twice must not accumulate rows. This is the idempotency
    /// claim at the service level, above the repository's own key handling.
    func testRecordingTheSameMeetingTwiceAddsNoDuplicates() async throws {
        let project = projectWithSourceMeeting()
        let transitions = InMemoryWorkStateTransitionRepository()
        let service = try await service(project: project, transitions: transitions)

        let first = try await service.recordTransitions(
            forProject: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            incoming: Fixtures.representativeInput().incoming
        )
        let second = try await service.recordTransitions(
            forProject: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            incoming: Fixtures.representativeInput().incoming
        )

        XCTAssertEqual(first.proposals, second.proposals)
        let stored = await transitions.allProposals()
        XCTAssertEqual(stored.count, first.proposals.count)
    }

    func testRefusalsAreStoredWithRunProjectAndMeetingIdentity() async throws {
        let project = projectWithSourceMeeting()
        let transitions = InMemoryWorkStateTransitionRepository()
        let service = try await service(project: project, transitions: transitions)
        let unknownActionItemID = Fixtures.uuid(999)

        let result = try await service.recordTransitions(
            forProject: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            incoming: Fixtures.representativeInput().incoming,
            progressSignals: [
                WorkStateProgressSignal(
                    kind: .completed,
                    actionItemID: unknownActionItemID,
                    evidence: Fixtures.signalEvidence()
                )
            ]
        )

        XCTAssertTrue(result.refusals.contains { $0.currentObjectID == unknownActionItemID })
        let stored = await transitions.allRefusals()
        let refusal = try XCTUnwrap(stored.first { $0.currentObjectID == unknownActionItemID })
        let expectedRun = WorkStateContinuityRunIdentity(
            projectID: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID
        )
        XCTAssertEqual(refusal.runID, expectedRun.runID)
        XCTAssertEqual(refusal.projectID, project.id)
        XCTAssertEqual(refusal.sourceMeetingID, Fixtures.sourceMeetingID)
        XCTAssertEqual(refusal.reason, .unknownReferencedObject)
    }

    /// `occurredAt` is read from the stored meeting, never from a parameter. If it were a parameter,
    /// a caller could make an approved task look overdue simply by passing a later date.
    func testLatenessIsJudgedAgainstTheStoredMeetingRatherThanTheCurrentClock() async throws {
        let project = projectWithSourceMeeting()
        let transitions = InMemoryWorkStateTransitionRepository()
        // `now` is decades after the meeting. If the engine were handed this clock instead of the
        // meeting's own time, the future-dated task would be judged late against it too.
        let service = try await service(
            project: project,
            transitions: transitions,
            now: distantFuture
        )

        let result = try await service.recordTransitions(
            forProject: project.id,
            sourceMeetingID: Fixtures.sourceMeetingID,
            incoming: Fixtures.representativeInput().incoming
        )

        let meeting = try XCTUnwrap(project.meetings.first { $0.id == Fixtures.sourceMeetingID })
        let delayed = result.proposals.filter { $0.transitionKind == .delayed }
        let overdueByMeetingTime = project.actionItems.filter {
            ApprovedWorkStatePolicy.isApproved($0)
                && ($0.dueDate.map { due in due < meeting.occurredAt } ?? false)
        }
        XCTAssertEqual(delayed.count, overdueByMeetingTime.count)
        XCTAssertEqual(
            delayed.count,
            1,
            "Only the task already overdue at meeting time is late; the future-dated one is not, "
                + "even though the clock has long since passed its due date."
        )
        XCTAssertFalse(
            delayed.contains { $0.previousStateID == Fixtures.uuid(950) },
            "A distant `now` must not make additional prior tasks overdue."
        )
        XCTAssertTrue(
            result.proposals.allSatisfy { $0.createdAt == distantFuture },
            "`now` is still what stamps createdAt — it is only barred from deciding lateness."
        )
    }

    // MARK: - Refusals to run

    func testAnUnknownProjectIsReportedRatherThanTreatedAsHavingNoPriorState() async throws {
        let service = try await service(
            project: nil,
            transitions: InMemoryWorkStateTransitionRepository()
        )

        do {
            _ = try await service.recordTransitions(
                forProject: Fixtures.projectID,
                sourceMeetingID: Fixtures.sourceMeetingID,
                incoming: Fixtures.representativeInput().incoming
            )
            XCTFail("expected projectNotFound")
        } catch let error as WorkStateContinuityError {
            XCTAssertEqual(error, .projectNotFound)
        }
    }

    func testAMeetingThatDoesNotBelongToTheProjectIsRefused() async throws {
        let project = projectWithSourceMeeting()
        let service = try await service(
            project: project,
            transitions: InMemoryWorkStateTransitionRepository()
        )

        do {
            _ = try await service.recordTransitions(
                forProject: project.id,
                sourceMeetingID: UUID(),
                incoming: Fixtures.representativeInput().incoming
            )
            XCTFail("expected meetingNotFound")
        } catch let error as WorkStateContinuityError {
            XCTAssertEqual(error, .meetingNotFound)
        }
    }

    func testAnUnreadableProjectIsDistinguishedFromAMissingOne() async throws {
        let clock = now
        let service = WorkStateContinuityService(
            projects: FailingProjectRepository(),
            transitions: InMemoryWorkStateTransitionRepository(),
            now: { clock }
        )

        do {
            _ = try await service.recordTransitions(
                forProject: Fixtures.projectID,
                sourceMeetingID: Fixtures.sourceMeetingID,
                incoming: Fixtures.representativeInput().incoming
            )
            XCTFail("expected projectRepositoryFailure")
        } catch let error as WorkStateContinuityError {
            XCTAssertEqual(
                error,
                .projectRepositoryFailure,
                "A read failure must not be reported as 'no such project'."
            )
        }
    }

    // MARK: - A failed write

    /// The distinction that matters most: transitions were computed and then lost. Reporting success
    /// here would tell the caller a record exists that does not.
    func testAFailedStoreIsReportedAsAFailureAndNotAsASuccessfulRun() async throws {
        let project = projectWithSourceMeeting()
        let projects = InMemoryProjectRepository()
        try await projects.save(project)
        let clock = now
        let service = WorkStateContinuityService(
            projects: projects,
            transitions: InMemoryWorkStateTransitionRepository(
                saveError: TransitionStoreUnavailable()
            ),
            now: { clock }
        )

        do {
            _ = try await service.recordTransitions(
                forProject: project.id,
                sourceMeetingID: Fixtures.sourceMeetingID,
                incoming: Fixtures.representativeInput().incoming
            )
            XCTFail("expected transitionStoreFailure")
        } catch let error as WorkStateContinuityError {
            XCTAssertEqual(error, .transitionStoreFailure)
        }

        // Approved work state survives the failure untouched — the whole point of writing
        // transitions to a separate file.
        let reloaded = try await projects.project(id: project.id)
        XCTAssertEqual(reloaded, project)
    }
}
