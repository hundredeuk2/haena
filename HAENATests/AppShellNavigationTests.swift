import XCTest
@testable import HAENA

final class AppShellNavigationTests: XCTestCase {
    private typealias F = MeetingResultFixtures

    func testFiveTypedDestinationsStartAtHomeWithoutSelection() {
        let state = AppShellNavigation()
        XCTAssertEqual(AppShellDestination.allCases, [.home, .review, .briefs, .transcripts, .projects])
        XCTAssertEqual(state.destination, .home)
        XCTAssertNil(state.projectID)
        XCTAssertNil(state.meetingID)
    }

    func testEveryRailDestinationPreservesProjectAndMeeting() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectA, meetingID: F.meetingA, pane: .meetings))
        for destination in AppShellDestination.allCases {
            state.select(destination)
            XCTAssertEqual(state.destination, destination)
            XCTAssertEqual(state.projectID, F.projectA)
            XCTAssertEqual(state.meetingID, F.meetingA)
        }
    }

    func testHomePendingReviewRoutesToExactProject() {
        var state = AppShellNavigation()
        state.open(.nextAction(.review(.init(projectID: F.projectB, projectName: "Synthetic", pendingCount: 3))))
        XCTAssertEqual(state.destination, .review)
        XCTAssertEqual(state.projectID, F.projectB)
        XCTAssertEqual(state.projectPane, .workState)
        XCTAssertNil(state.actionItemID)
        XCTAssertNil(state.meetingID)
    }

    func testActionLinkRetainsExactIDAndIsNotAFilterAfterRailNavigation() {
        var state = AppShellNavigation()
        let id = UUID()
        state.open(.init(projectID: F.projectA, actionItemID: id, pane: .workState))
        // Product-owner approved 2.5 rebaseline: approved work is owned by Projects.
        XCTAssertEqual(state.destination, .projects)
        XCTAssertEqual(state.actionItemID, id)
        state.select(.home)
        XCTAssertNil(state.actionItemID)
    }

    func testCaptureOpensExactMeetingResultsNotTranscript() {
        var state = AppShellNavigation()
        state.open(.results(of: .init(projectID: F.projectA, meetingID: F.meetingB)))
        XCTAssertEqual(state.destination, .transcripts)
        XCTAssertEqual(state.projectID, F.projectA)
        XCTAssertEqual(state.meetingID, F.meetingB)
        XCTAssertEqual(state.projectPane, .meetings)
        XCTAssertEqual(state.meetingPane, .results)
        state.select(.transcripts)
        XCTAssertEqual(state.meetingPane, .transcript)
    }

    func testStatusLinkMapsToProjects() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectA, pane: .status))
        XCTAssertEqual(state.destination, .projects)
        XCTAssertEqual(state.projectPane, .status)
    }

    func testRepeatedExplicitLinkIssuesNewRequestButRailDoesNot() {
        var state = AppShellNavigation()
        let request = BrowserDestination(projectID: F.projectA, pane: .workState)
        state.open(request)
        let first = state.requestID
        state.select(.home)
        XCTAssertEqual(state.requestID, first)
        state.open(request)
        XCTAssertNotEqual(state.requestID, first)
    }

    func testDifferentProjectClearsMeetingAndActionSelection() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectA, meetingID: F.meetingA, actionItemID: UUID(), pane: .workState))
        state.selectProject(F.projectB)
        XCTAssertEqual(state.projectID, F.projectB)
        XCTAssertNil(state.meetingID)
        XCTAssertNil(state.actionItemID)
        XCTAssertEqual(state.projectPane, .status)
    }

    func testSelectingSameProjectKeepsMeeting() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectA, meetingID: F.meetingA, pane: .meetings))
        state.selectProject(F.projectA)
        XCTAssertEqual(state.meetingID, F.meetingA)
    }

    func testMissingMeetingFallsBackToItsProjectAndMissingProjectToEmpty() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectA, meetingID: UUID(), pane: .meetings))
        state.validate(in: [F.project()])
        XCTAssertEqual(state.projectID, F.projectA)
        XCTAssertNil(state.meetingID)
        state.validate(in: [])
        XCTAssertNil(state.projectID)
        XCTAssertEqual(state.destination, .transcripts)
    }

    func testValidationNeverFindsMeetingOutsideRequestedProject() {
        var state = AppShellNavigation()
        state.open(.init(projectID: F.projectB, meetingID: F.meetingA, pane: .meetings))
        state.validate(in: [F.project(), F.project(id: F.projectB, meetings: [])])
        XCTAssertEqual(state.projectID, F.projectB)
        XCTAssertNil(state.meetingID)
    }

    func testNavigationDoesNotChangeSyntheticDomainBytes() throws {
        let projects = [F.project()]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(projects)
        var state = AppShellNavigation()
        for destination in AppShellDestination.allCases {
            state.open(.init(projectID: F.projectA, meetingID: F.meetingA, pane: .workState))
            state.select(destination)
            state.validate(in: projects)
        }
        XCTAssertEqual(try encoder.encode(projects), before)
    }
}
