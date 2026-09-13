#if DEBUG
import XCTest
@testable import HAENA

final class CaptureNavigationUITestSeedTests: XCTestCase {
    private let enabled = ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_CAPTURE_PREFILL": "1"]

    func testProductionInitialStateIsEmpty() {
        XCTAssertEqual(PastedTranscriptInitialState(), .empty)
        XCTAssertNil(PastedTranscriptInitialState.empty.selectedProjectID)
        XCTAssertEqual(PastedTranscriptInitialState.empty.meetingTitle, "")
        XCTAssertEqual(PastedTranscriptInitialState.empty.transcript, "")
    }

    func testBothOptInsAreRequired() {
        for environment in [[:], ["HAENA_UI_TESTING": "1"], ["HAENA_UI_TEST_CAPTURE_PREFILL": "1"]] {
            XCTAssertNil(CaptureNavigationUITestSeed.select(environment: environment))
        }
    }

    func testOptInDoesNotAcceptArbitraryTruthyValues() {
        for value in ["true", "YES", "0", "", "synthetic"] {
            XCTAssertNil(CaptureNavigationUITestSeed.select(environment: [
                "HAENA_UI_TESTING": "1", "HAENA_UI_TEST_CAPTURE_PREFILL": value
            ]))
            XCTAssertNil(CaptureNavigationUITestSeed.select(environment: [
                "HAENA_UI_TESTING": value, "HAENA_UI_TEST_CAPTURE_PREFILL": "1"
            ]))
        }
    }

    func testEnvironmentCannotSupplyRawContentOrProjectIdentity() throws {
        var environment = enabled
        environment["meetingTitle"] = "ignored"
        environment["transcript"] = "ignored"
        environment["selectedProjectID"] = UUID().uuidString
        let seed = try XCTUnwrap(CaptureNavigationUITestSeed.select(environment: environment))
        XCTAssertEqual(seed.initialState, CaptureNavigationUITestSeed.select(environment: enabled)?.initialState)
        XCTAssertEqual(seed.initialState.meetingTitle, "Shell Synthetic Meeting")
        XCTAssertEqual(seed.initialState.transcript, "Synthetic navigation-only transcript.")
    }

    func testSeedIsFixedAndHasNoSavedMeetingOrApprovedOutput() throws {
        let first = try XCTUnwrap(CaptureNavigationUITestSeed.select(environment: enabled))
        let second = try XCTUnwrap(CaptureNavigationUITestSeed.select(environment: enabled))
        XCTAssertEqual(first.project, second.project)
        XCTAssertEqual(first.initialState, second.initialState)
        XCTAssertEqual(first.project.id.uuidString, "C9000000-0000-4000-8000-000000000001")
        XCTAssertEqual(first.initialState.selectedProjectID, first.project.id)
        XCTAssertTrue(first.project.meetings.isEmpty)
        XCTAssertTrue(first.project.decisions.isEmpty)
        XCTAssertTrue(first.project.actionItems.isEmpty)
        XCTAssertTrue(first.project.openQuestions.isEmpty)
        XCTAssertTrue(first.project.nextAgenda.isEmpty)
    }

    func testOnlyExplicitCaptureSavesOneMeetingWithExactSeedContent() async throws {
        let seed = try XCTUnwrap(CaptureNavigationUITestSeed.select(environment: enabled))
        let repository = InMemoryProjectRepository(projects: [seed.project])
        let before = try await repository.project(id: seed.project.id)
        XCTAssertEqual(before, seed.project)
        let service = TextMeetingCaptureService(repository: repository)
        let meeting = try await service.saveTextMeeting(
            projectID: seed.initialState.selectedProjectID,
            title: seed.initialState.meetingTitle, transcript: seed.initialState.transcript
        )
        let after = try await repository.project(id: seed.project.id)
        XCTAssertEqual(after?.meetings.count, 1)
        XCTAssertEqual(meeting.projectID, seed.project.id)
        XCTAssertEqual(meeting.title, seed.initialState.meetingTitle)
        XCTAssertEqual(meeting.transcriptSegments.map(\.text), [seed.initialState.transcript])
        XCTAssertEqual(after?.decisions, [])
        XCTAssertEqual(after?.actionItems, [])
        XCTAssertEqual(after?.openQuestions, [])
        XCTAssertEqual(after?.nextAgenda, [])
        let independent = InMemoryProjectRepository()
        let untouched = try await independent.allProjects()
        XCTAssertTrue(untouched.isEmpty)
    }
}
#endif
