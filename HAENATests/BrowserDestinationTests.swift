import XCTest
@testable import HAENA

/// Where the browser lands when a capture hands it a meeting, and what it does when that meeting
/// is not there any more.
final class BrowserDestinationTests: XCTestCase {
    private typealias Fixtures = MeetingResultFixtures

    private var projects: [Project] {
        [
            Fixtures.project(),
            Fixtures.project(
                id: Fixtures.projectB,
                meetings: [Fixtures.meeting(id: Fixtures.uuid(500), inProject: Fixtures.projectB)]
            )
        ]
    }

    // MARK: - What a capture asks for

    func testACaptureAsksForItsMeetingOnTheMeetingList() {
        let capture = CaptureDestination(projectID: Fixtures.projectA, meetingID: Fixtures.meetingA)

        let destination = BrowserDestination.results(of: capture)

        XCTAssertEqual(destination.projectID, Fixtures.projectA)
        XCTAssertEqual(destination.meetingID, Fixtures.meetingA)
        XCTAssertEqual(destination.pane, .meetings, "The meeting the user just made has to be visible")
    }

    /// The pane the meeting itself opens on. Asserted here rather than left to the `@State`
    /// initialiser, because "a meeting opens on its results" is the point of the whole flow.
    func testAMeetingOpensOnItsResults() {
        XCTAssertEqual(MeetingDetailPane.initial, .results)
    }

    // MARK: - What the home's 지금 할 일 card asks for

    /// A review recommendation opens the project it named, on the pane that holds the proposals.
    /// The project has to be the exact one the card counted — landing on any other would show the
    /// user a different number than the one they pressed.
    func testAReviewRecommendationOpensThatProjectsWorkState() {
        let review = NextAction.Review(
            projectID: Fixtures.projectB,
            projectName: "고객 온보딩",
            pendingCount: 3
        )

        let destination = BrowserDestination.nextAction(.review(review))
        XCTAssertEqual(destination.target, .pendingReview)

        XCTAssertEqual(destination.projectID, Fixtures.projectB)
        XCTAssertEqual(destination.pane, .workState)
        XCTAssertNil(
            destination.actionItemID,
            "A pile of proposals is not one item, and singling one out would be a judgement the home cannot make"
        )
        XCTAssertNil(destination.meetingID)
    }

    /// A task recommendation names the task as well as the project, so 업무 상태 can open on the
    /// item rather than on a list the user has to search for what they just pressed.
    func testATaskRecommendationOpensTheExactProjectAndItem() {
        let work = NextAction.Work(
            actionItemID: Fixtures.uuid(700),
            title: "지표 정의",
            projectID: Fixtures.projectB,
            projectName: "고객 온보딩",
            assigneeName: "이헌득",
            dueDateLabel: "마감일 없음",
            isOverdue: false
        )

        let destination = BrowserDestination.nextAction(.work(work))
        XCTAssertEqual(destination.target, .approvedWorkState(.actionItem(Fixtures.uuid(700))))

        XCTAssertEqual(destination.projectID, Fixtures.projectB)
        XCTAssertEqual(destination.actionItemID, Fixtures.uuid(700))
        XCTAssertEqual(destination.pane, .workState)
        XCTAssertNil(destination.meetingID, "The task is reached through the project, not through a meeting")
    }

    /// The item request is answered by the same resolver every other initial selection goes
    /// through, so a project deleted since the home last loaded selects nothing rather than
    /// half-opening on a task that is gone with it.
    func testATaskRecommendationForAMissingProjectSelectsNothing() {
        let destination = BrowserDestination.nextAction(
            .work(
                NextAction.Work(
                    actionItemID: Fixtures.uuid(700),
                    title: "지표 정의",
                    projectID: Fixtures.uuid(998),
                    projectName: "삭제된 프로젝트",
                    assigneeName: nil,
                    dueDateLabel: "마감일 없음",
                    isOverdue: false
                )
            )
        )

        XCTAssertEqual(
            BrowserInitialSelection.resolve(
                projectID: destination.projectID,
                meetingID: destination.meetingID,
                in: projects
            ),
            .none
        )
    }

    // MARK: - Resolving against what is actually stored

    func testSelectsTheRequestedMeetingWhenItExists() {
        let selection = BrowserInitialSelection.resolve(
            projectID: Fixtures.projectA,
            meetingID: Fixtures.meetingB,
            in: projects
        )

        XCTAssertEqual(selection, .meeting(projectID: Fixtures.projectA, meetingID: Fixtures.meetingB))
        XCTAssertEqual(selection.projectID, Fixtures.projectA)
        XCTAssertEqual(selection.meetingID, Fixtures.meetingB)
    }

    /// A meeting that belongs to a different project is not "found" just because it exists
    /// somewhere — selecting it under the wrong project would show the user someone else's work.
    func testDoesNotSelectAMeetingFromADifferentProject() {
        let selection = BrowserInitialSelection.resolve(
            projectID: Fixtures.projectA,
            meetingID: Fixtures.uuid(500),
            in: projects
        )

        XCTAssertEqual(selection, .project(Fixtures.projectA))
        XCTAssertNil(selection.meetingID)
    }

    /// Deleted between the capture finishing and the browser opening: fall back one step, to the
    /// project, rather than to nothing.
    func testFallsBackToTheProjectWhenTheMeetingIsGone() {
        let selection = BrowserInitialSelection.resolve(
            projectID: Fixtures.projectA,
            meetingID: Fixtures.uuid(999),
            in: projects
        )

        XCTAssertEqual(selection, .project(Fixtures.projectA))
    }

    func testSelectsNothingWhenTheProjectIsGone() {
        let selection = BrowserInitialSelection.resolve(
            projectID: Fixtures.uuid(998),
            meetingID: Fixtures.meetingA,
            in: projects
        )

        XCTAssertEqual(selection, .none)
        XCTAssertNil(selection.projectID)
        XCTAssertNil(selection.meetingID)
    }

    func testSelectsNothingWhenNothingWasRequested() {
        XCTAssertEqual(BrowserInitialSelection.resolve(projectID: nil, meetingID: nil, in: projects), .none)
        XCTAssertEqual(
            BrowserInitialSelection.resolve(projectID: nil, meetingID: Fixtures.meetingA, in: projects),
            .none,
            "A meeting id alone says nothing about which project to open"
        )
    }

    func testSelectsOnlyTheProjectWhenNoMeetingWasRequested() {
        let selection = BrowserInitialSelection.resolve(
            projectID: Fixtures.projectA,
            meetingID: nil,
            in: projects
        )

        XCTAssertEqual(selection, .project(Fixtures.projectA))
    }

    func testHandlesAnEmptyStoreWithoutSelectingAnything() {
        XCTAssertEqual(
            BrowserInitialSelection.resolve(projectID: Fixtures.projectA, meetingID: Fixtures.meetingA, in: []),
            .none
        )
    }

    /// A project with no meetings cannot satisfy a meeting request, and must not be mistaken for
    /// one that can.
    func testFallsBackToAProjectThatHasNoMeetings() {
        let empty = Project(
            id: Fixtures.projectB,
            name: "빈 프로젝트",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        XCTAssertEqual(
            BrowserInitialSelection.resolve(
                projectID: Fixtures.projectB,
                meetingID: Fixtures.meetingA,
                in: [empty]
            ),
            .project(Fixtures.projectB)
        )
    }
}
