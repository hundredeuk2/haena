import XCTest
@testable import HAENA

final class ActionItemReminderSampleTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(
        projects: InMemoryProjectRepository,
        profiles: InMemoryLocalUserProfileRepository
    ) -> ActionItemReminderSampleService {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return ActionItemReminderSampleService(
            projectRepository: projects,
            profileRepository: profiles,
            calendar: calendar,
            now: { Self.now }
        )
    }

    func testCreatesCompleteEligibleReminderSample() async throws {
        let projects = InMemoryProjectRepository()
        let profiles = InMemoryLocalUserProfileRepository()

        let result = try await service(projects: projects, profiles: profiles).createOrReset()
        let storedProject = try await projects.project(id: result.projectID)
        let project = try XCTUnwrap(storedProject)
        let item = try XCTUnwrap(project.actionItems.first { $0.id == result.actionItemID })
        let storedProfile = try await profiles.profile()
        let profile = try XCTUnwrap(storedProfile)

        XCTAssertEqual(item.status, .confirmed)
        XCTAssertEqual(item.assigneeID, ActionItemReminderSampleService.participantID)
        XCTAssertGreaterThan(try XCTUnwrap(item.dueDate), Self.now)
        XCTAssertTrue(profile.isLinked(ActionItemReminderSampleService.participantID))
        XCTAssertEqual(ActionItemReminderService.eligibility(of: item, profile: profile), .eligible)
        XCTAssertTrue(project.meetings.contains { $0.id == result.meetingID })
    }

    func testPreservesExistingProfileNameAndLinks() async throws {
        let existingParticipant = UUID()
        let profile = LocalUserProfile(
            displayName: "패트릭",
            linkedParticipantIDs: [existingParticipant],
            createdAt: Self.now.addingTimeInterval(-10_000),
            updatedAt: Self.now.addingTimeInterval(-10_000)
        )
        let projects = InMemoryProjectRepository()
        let profiles = InMemoryLocalUserProfileRepository(profile: profile)

        _ = try await service(projects: projects, profiles: profiles).createOrReset()
        let storedProfile = try await profiles.profile()
        let saved = try XCTUnwrap(storedProfile)

        XCTAssertEqual(saved.displayName, "패트릭")
        XCTAssertTrue(saved.isLinked(existingParticipant))
        XCTAssertTrue(saved.isLinked(ActionItemReminderSampleService.participantID))
    }

    func testPressingAgainResetsOneSampleInsteadOfDuplicatingIt() async throws {
        let projects = InMemoryProjectRepository()
        let profiles = InMemoryLocalUserProfileRepository()
        let sample = service(projects: projects, profiles: profiles)

        let first = try await sample.createOrReset()
        let firstStoredProject = try await projects.project(id: first.projectID)
        var project = try XCTUnwrap(firstStoredProject)
        let index = try XCTUnwrap(project.actionItems.firstIndex { $0.id == first.actionItemID })
        project.actionItems[index].status = .completed
        try await projects.save(project)

        let second = try await sample.createOrReset()
        let secondStoredProject = try await projects.project(id: second.projectID)
        let reloaded = try XCTUnwrap(secondStoredProject)

        XCTAssertEqual(reloaded.meetings.filter { $0.id == second.meetingID }.count, 1)
        XCTAssertEqual(reloaded.actionItems.filter { $0.id == second.actionItemID }.count, 1)
        XCTAssertEqual(reloaded.actionItems.first { $0.id == second.actionItemID }?.status, .confirmed)
    }
}
