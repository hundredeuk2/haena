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
