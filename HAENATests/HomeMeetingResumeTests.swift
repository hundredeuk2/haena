#if DEBUG
import XCTest
@testable import HAENA

final class HomeMeetingResumeTests: XCTestCase {
    func testEmptyHasNoResumeOrInventedNextAction() {
        XCTAssertNil(HomeMeetingResume.latest(in: []))
        XCTAssertNil(HomeSummary(projects: []).nextAction)
    }

    func testPendingReviewWinsAndRoutesToExistingReviewOwner() throws {
        let seed = HomeUITestSeed.make(.pendingReview)
        let summary = HomeSummary(projects: seed.projects, profile: seed.profile)
        guard case .review(let review) = summary.nextAction else { return XCTFail("Expected pending review") }
        XCTAssertEqual(review.pendingCount, 1)
        XCTAssertEqual(BrowserDestination.nextAction(.review(review)).projectID, seed.projects[0].id)
        XCTAssertEqual(BrowserDestination.nextAction(.review(review)).pane, .workState)
        let row = try XCTUnwrap(HomeMeetingResume.latest(in: seed.projects))
        XCTAssertEqual(row.stage, .needsReview)
        XCTAssertEqual(row.pendingCount, 1)
    }

    func testAssignedWorkUsesExplicitLinkedParticipantAndExactActionID() throws {
        let seed = HomeUITestSeed.make(.assignedWork)
        guard case .work(let work) = HomeSummary(projects: seed.projects, profile: seed.profile).nextAction else {
            return XCTFail("Expected linked work")
        }
        XCTAssertEqual(work.actionItemID, seed.projects[0].actionItems[0].id)
        XCTAssertEqual(BrowserDestination.nextAction(.work(work)).actionItemID, work.actionItemID)
        XCTAssertEqual(HomeMeetingResume.latest(in: seed.projects)?.stage, .savedResults)
    }

    func testNoProfileNeverRecommendsSomebodyElsesWork() {
        let seed = HomeUITestSeed.make(.noProfile)
        let summary = HomeSummary(projects: seed.projects, profile: seed.profile)
        XCTAssertNil(summary.nextAction)
        XCTAssertFalse(summary.isPersonalised)
        XCTAssertEqual(summary.activeActionItems.totalCount, 1)
        XCTAssertNotNil(HomeMeetingResume.latest(in: seed.projects))
    }

    func testLoadFailureStaysAnErrorNotAnEmptyAccount() async {
        do {
            _ = try await ProjectBrowserQueryService(repository: HomeLoadFailureUITestRepository()).loadProjects()
            XCTFail("Must not render a successful empty load")
        } catch { XCTAssertTrue(error is HomeLoadFailureUITestRepository.Failure) }
    }

    func testRestartReconstructionPreservesCanonicalValuesAndResume() async throws {
        let seed = HomeUITestSeed.make(.resume)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(seed.projects)
        let restored = try JSONDecoder().decode([Project].self, from: bytes)
        let repository = InMemoryProjectRepository(projects: restored)
        let loaded = try await repository.allProjects()
        XCTAssertEqual(HomeMeetingResume.latest(in: loaded), HomeMeetingResume.latest(in: seed.projects))
        XCTAssertEqual(HomeSummary(projects: loaded, profile: seed.profile).nextAction,
                       HomeSummary(projects: seed.projects, profile: seed.profile).nextAction)
        XCTAssertEqual(try encoder.encode(loaded), bytes)
        XCTAssertEqual(loaded, seed.projects) // IDs, transcript/evidence, assignee, due and approval unchanged.
    }

    func testNoOutputsDoesNotClaimExtractionCompleteOrMissing() {
        var project = HomeUITestSeed.make(.resume).projects[0]
        project.actionItems = []
        XCTAssertEqual(HomeMeetingResume.latest(in: [project])?.stage, .savedMeeting)
        XCTAssertEqual(HomeMeetingResume.latest(in: [project])?.pendingCount, 0)
    }

    func testProcessedOutputsAreNotPendingAndNeverDisappearIntoNoResults() {
        var project = HomeUITestSeed.make(.resume).projects[0]
        project.actionItems[0].status = .cancelled
        XCTAssertEqual(HomeMeetingResume.latest(in: [project])?.stage, .savedResults)
        XCTAssertEqual(HomeMeetingResume.latest(in: [project])?.pendingCount, 0)
    }

    func testLatestSelectionIsDeterministicAndUsesExactMeetingOwner() throws {
        var project = HomeUITestSeed.make(.resume).projects[0]
        let first = project.meetings[0]
        let other = Meeting(id: UUID(uuidString: "CA000000-0000-4000-8000-000000000099")!,
                            projectID: project.id, title: first.title, occurredAt: first.occurredAt,
                            sourceType: .pastedText, participants: [], transcriptSegments: [], createdAt: first.createdAt)
        project.meetings.append(other)
        let row = try XCTUnwrap(HomeMeetingResume.latest(in: [project]))
        project.meetings.reverse()
        XCTAssertEqual(HomeMeetingResume.latest(in: [project]), row)
        XCTAssertEqual(row.meetingID, first.id)
        XCTAssertEqual(row.destination, .results(of: CaptureDestination(projectID: project.id, meetingID: first.id)))
        project.meetings[0].occurredAt = first.occurredAt.addingTimeInterval(1)
        XCTAssertEqual(HomeMeetingResume.latest(in: [project])?.meetingID, other.id)
    }

    func testForeignMeetingAndForeignOutputCannotClaimOwnership() {
        var project = HomeUITestSeed.make(.resume).projects[0]
        let other = Project(id: UUID(), name: "Foreign", summary: "", createdAt: project.createdAt,
                            updatedAt: project.updatedAt, meetings: project.meetings, decisions: [],
                            actionItems: project.actionItems, openQuestions: [], nextAgenda: [])
        XCTAssertNil(HomeMeetingResume.latest(in: [other]))
        project.meetings = []
        XCTAssertNil(HomeMeetingResume.latest(in: [project]))
    }

    func testSeedRequiresStrictOptInAndKnownFiniteScenario() {
        for env in [[:], ["HAENA_UI_TEST_HOME": "resume"], ["HAENA_UI_TESTING": "1"],
                    ["HAENA_UI_TESTING": "true", "HAENA_UI_TEST_HOME": "resume"],
                    ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_HOME": "arbitrary"]] {
            XCTAssertNil(HomeUITestSeed.select(environment: env))
        }
        for scenario in HomeUITestSeed.Scenario.allCases {
            let env = ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_HOME": scenario.rawValue, "transcript": "ignored"]
            XCTAssertEqual(HomeUITestSeed.select(environment: env)?.projects, HomeUITestSeed.make(scenario).projects)
        }
    }

    @MainActor
    func testAllNewHomeStringsHaveExplicitKoreanAndEnglishTranslations() {
        let entries = [
            ("Home 도구", "Home Tools"),
            ("회의를 남기고, 제안을 검토하고, 다음 할 일을 이어가세요.", "Capture a meeting, review its suggestions, and continue your next task."),
            ("최근 회의", "Latest Meeting"),
            ("저장 상태: 검토 필요", "Saved state: review needed"),
            ("저장 상태: 검토할 제안 없음", "Saved state: no proposals awaiting review"),
            ("저장 상태: 회의 저장됨 · 결과 없음", "Saved state: meeting saved · no results"),
            ("이 회의의 미검토 제안: %@", "Unreviewed proposals in this meeting: %@"),
            ("저장된 회의가 없습니다.", "No saved meetings."),
            ("프로젝트 요약", "Project Summary")
        ]
        for (ko, en) in entries {
            XCTAssertEqual(L10n.text(ko, language: .ko), ko)
            XCTAssertEqual(L10n.text(ko, language: .en), en)
        }
    }
}
#endif
