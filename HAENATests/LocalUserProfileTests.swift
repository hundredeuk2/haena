import XCTest
@testable import HAENA

/// Covers the local profile: storing a name, linking meeting participants to the user, surviving a
/// restart, and refusing to guess who anyone is.
final class LocalUserProfileTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let later = Date(timeIntervalSince1970: 1_700_000_500)

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory!)
        }
    }

    // MARK: - Helpers

    private func makeService(
        projects: [Project] = [],
        profileRepository: any LocalUserProfileRepository = InMemoryLocalUserProfileRepository(),
        now: Date = LocalUserProfileTests.now
    ) async throws -> LocalUserProfileService {
        let projectRepository = InMemoryProjectRepository()
        for project in projects {
            try await projectRepository.save(project)
        }
        return LocalUserProfileService(
            profileRepository: profileRepository,
            projectRepository: projectRepository,
            now: { now },
            makeID: { Fixture.profileID }
        )
    }

    // MARK: - No profile yet

    func testAFreshInstallHasNoProfileAndThatIsNotAnError() async throws {
        let service = try await makeService()
        let profile = try await service.profile()
        XCTAssertNil(profile)
        XCTAssertFalse(MyWorkPolicy.isPersonalised(profile))
    }

    /// A store file written before this feature existed has no profile file beside it. It must read
    /// as "not set up", not as a failure.
    func testAStoreWithNoProfileFileLoadsAsNotSetUp() async throws {
        let repository = JSONLocalUserProfileRepository(
            fileURL: directory.appendingPathComponent("profile.json")
        )
        let profile = try await repository.profile()
        XCTAssertNil(profile)
    }

    /// The existing project data is untouched by this feature — same file, same schema version.
    func testTheProjectStoreSchemaIsUnchanged() async throws {
        let projectsURL = directory.appendingPathComponent("projects.json")
        let projects = JSONProjectRepository(fileURL: projectsURL)
        try await projects.save(Fixture.project())

        let raw = try XCTUnwrap(String(data: try Data(contentsOf: projectsURL), encoding: .utf8))
        XCTAssertTrue(raw.contains("\"schemaVersion\":1"))
        XCTAssertFalse(raw.contains("profile"), "The profile must not have leaked into the project store.")
        XCTAssertEqual(ProjectStoreFile.currentSchemaVersion, 1)
    }

    // MARK: - Naming

    func testSettingAndChangingTheName() async throws {
        let store = InMemoryLocalUserProfileRepository()
        let service = try await makeService(profileRepository: store)

        let created = try await service.setDisplayName("이헌득")
        XCTAssertEqual(created.displayName, "이헌득")
        XCTAssertEqual(created.id, Fixture.profileID)
        XCTAssertFalse(created.isIdentified, "Naming yourself is not the same as saying which participants are you.")

        let renamed = try await LocalUserProfileService(
            profileRepository: store,
            projectRepository: InMemoryProjectRepository(),
            now: { Self.later },
            makeID: { Fixture.profileID }
        ).setDisplayName("  다른 이름  ")

        XCTAssertEqual(renamed.displayName, "다른 이름", "Surrounding whitespace is trimmed.")
        XCTAssertEqual(renamed.id, Fixture.profileID, "Renaming must not create a second profile.")
        XCTAssertEqual(renamed.createdAt, Self.now)
        XCTAssertEqual(renamed.updatedAt, Self.later)
    }

    func testABlankNameIsRejected() async throws {
        let service = try await makeService()

        for candidate in ["", "   ", "\n\t "] {
            do {
                _ = try await service.setDisplayName(candidate)
                XCTFail("Expected a blank name to be refused.")
            } catch let error as LocalUserProfileError {
                XCTAssertEqual(error, .nameMissing)
            }
        }
        let profile = try await service.profile()
        XCTAssertNil(profile, "A refused name must not leave a half-made profile behind.")
    }

    /// One person uses this app. Saving twice must update the single profile, never accumulate.
    func testOnlyOneProfileEverExists() async throws {
        let store = InMemoryLocalUserProfileRepository()
        let service = try await makeService(profileRepository: store)

        _ = try await service.setDisplayName("첫 이름")
        _ = try await service.setDisplayName("둘째 이름")

        let profile = try await XCTUnwrapAsync(await service.profile())
        XCTAssertEqual(profile.displayName, "둘째 이름")
        XCTAssertEqual(profile.id, Fixture.profileID)
    }

    // MARK: - Linking participants

    func testLinkingAndUnlinkingOneParticipant() async throws {
        let project = Fixture.project()
        let store = InMemoryLocalUserProfileRepository()
        let service = try await makeService(projects: [project], profileRepository: store)
        _ = try await service.setDisplayName("나")

        var profile = try await service.link(participantIDs: [Fixture.participantA])
        XCTAssertTrue(profile.isLinked(Fixture.participantA))
        XCTAssertTrue(profile.isIdentified)

        profile = try await service.unlink(participantID: Fixture.participantA)
        XCTAssertFalse(profile.isLinked(Fixture.participantA))
        XCTAssertFalse(profile.isIdentified)
    }

    /// The same human appears as a separate participant in every meeting, so identifying yourself
    /// means naming several of them — across projects.
    func testTheUserCanLinkParticipantsFromSeveralProjectsAtOnce() async throws {
        let first = Fixture.project()
        let second = Fixture.otherProject()
        let service = try await makeService(projects: [first, second])
        _ = try await service.setDisplayName("나")

        let profile = try await service.link(participantIDs: [Fixture.participantA, Fixture.participantC])

        XCTAssertTrue(profile.isLinked(Fixture.participantA))
        XCTAssertTrue(profile.isLinked(Fixture.participantC))
        XCTAssertEqual(profile.linkedParticipantIDs.count, 2)
    }

    func testLinkingTheSameParticipantTwiceDoesNotDuplicateIt() async throws {
        let service = try await makeService(projects: [Fixture.project()])
        _ = try await service.setDisplayName("나")

        _ = try await service.link(participantIDs: [Fixture.participantA])
        let profile = try await service.link(participantIDs: [Fixture.participantA, Fixture.participantA])

        XCTAssertEqual(profile.linkedParticipantIDs, [Fixture.participantA])
    }

    /// The load-bearing identification rule: a shared display name is not evidence of anything.
    func testParticipantsWithTheSameNameAreNeverLinkedAutomatically() async throws {
        // Two different people, same name, different meetings.
        let service = try await makeService(projects: [Fixture.project(), Fixture.sameNameProject()])
        _ = try await service.setDisplayName("서연")

        let afterNaming = try await XCTUnwrapAsync(await service.profile())
        XCTAssertTrue(
            afterNaming.linkedParticipantIDs.isEmpty,
            "Naming yourself must never link anyone, however exactly the names match."
        )

        let profile = try await service.link(participantIDs: [Fixture.participantA])
        XCTAssertTrue(profile.isLinked(Fixture.participantA))
        XCTAssertFalse(
            profile.isLinked(Fixture.participantD),
            "The identically named participant in another meeting stays unlinked."
        )
    }

    func testLinkingAParticipantThatDoesNotExistIsRefused() async throws {
        let service = try await makeService(projects: [Fixture.project()])
        _ = try await service.setDisplayName("나")

        do {
            _ = try await service.link(participantIDs: [UUID()])
            XCTFail("Expected an unknown participant to be refused.")
        } catch let error as LocalUserProfileError {
            XCTAssertEqual(error, .unknownParticipant)
        }

        let profile = try await XCTUnwrapAsync(await service.profile())
        XCTAssertTrue(profile.linkedParticipantIDs.isEmpty, "A refused link must store nothing.")
    }

    /// A link whose meeting was later deleted must stay harmless — never crash, never match work,
    /// and always be removable.
    func testALinkWhoseMeetingWasDeletedIsInertAndStillRemovable() async throws {
        let store = InMemoryLocalUserProfileRepository()
        let withProject = try await makeService(projects: [Fixture.project()], profileRepository: store)
        _ = try await withProject.setDisplayName("나")
        _ = try await withProject.link(participantIDs: [Fixture.participantA])

        // The project — and with it the meeting and its participants — is gone.
        let afterDeletion = try await makeService(projects: [], profileRepository: store)
        let profile = try await XCTUnwrapAsync(await afterDeletion.profile())

        XCTAssertTrue(profile.isLinked(Fixture.participantA), "The stored link survives; it simply matches nothing.")
        XCTAssertFalse(MyWorkPolicy.isMine(Fixture.actionItem(assignee: Fixture.participantA), profile: nil))
        let directoryAfterDeletion = try await afterDeletion.directory()
        XCTAssertTrue(directoryAfterDeletion.isEmpty)

        let cleaned = try await afterDeletion.unlink(participantID: Fixture.participantA)
        XCTAssertFalse(cleaned.isLinked(Fixture.participantA))
    }

    /// Speaker resolution is a different question — which voice is which person, inside one meeting.
    /// Identifying the app's user must not read or write it.
    func testProfileLinkingIsIndependentOfSpeakerResolutions() async throws {
        let project = Fixture.projectWithSpeakerResolution()
        let service = try await makeService(projects: [project])
        _ = try await service.setDisplayName("나")
        _ = try await service.link(participantIDs: [Fixture.participantA])

        let stored = try await XCTUnwrapAsync(await InMemoryProjectRepositoryHolder.reload(project))
        XCTAssertEqual(
            stored.meetings.first?.speakerResolutions,
            project.meetings.first?.speakerResolutions,
            "Existing speaker resolutions must be left exactly as they were."
        )
    }

    // MARK: - Round trip

    func testProfileAndLinksSurviveARestart() async throws {
        let fileURL = directory.appendingPathComponent("profile.json")
        let project = Fixture.project()

        let first = try await makeService(
            projects: [project],
            profileRepository: JSONLocalUserProfileRepository(fileURL: fileURL)
        )
        _ = try await first.setDisplayName("이헌득")
        _ = try await first.link(participantIDs: [Fixture.participantA, Fixture.participantB])

        // A brand new repository instance over the same file — the app relaunching.
        let second = try await makeService(
            projects: [project],
            profileRepository: JSONLocalUserProfileRepository(fileURL: fileURL)
        )
        let reloaded = try await XCTUnwrapAsync(await second.profile())

        XCTAssertEqual(reloaded.displayName, "이헌득")
        XCTAssertEqual(reloaded.id, Fixture.profileID)
        XCTAssertTrue(reloaded.isLinked(Fixture.participantA))
        XCTAssertTrue(reloaded.isLinked(Fixture.participantB))
        XCTAssertEqual(reloaded.createdAt, Self.now)
    }

    /// No account fields, now or by accident later.
    func testTheStoredFileContainsNoAccountFields() async throws {
        let fileURL = directory.appendingPathComponent("profile.json")
        let service = try await makeService(
            projects: [Fixture.project()],
            profileRepository: JSONLocalUserProfileRepository(fileURL: fileURL)
        )
        _ = try await service.setDisplayName("이헌득")
        _ = try await service.link(participantIDs: [Fixture.participantA])

        let raw = try XCTUnwrap(String(data: try Data(contentsOf: fileURL), encoding: .utf8))
        for forbidden in ["email", "password", "token", "organization", "organisation", "workspace", "accountID"] {
            XCTAssertFalse(raw.lowercased().contains(forbidden.lowercased()), "\(forbidden) must not be stored.")
        }
        XCTAssertTrue(raw.contains("\"schemaVersion\":1"))
    }

    // MARK: - Directory

    func testTheDirectoryShowsEveryParticipantWithItsProjectAndMeeting() async throws {
        let service = try await makeService(projects: [Fixture.project(), Fixture.otherProject()])
        _ = try await service.setDisplayName("나")
        _ = try await service.link(participantIDs: [Fixture.participantA])

        let entries = try await service.directory()

        XCTAssertEqual(entries.count, 3)
        let linked = try XCTUnwrap(entries.first)
        XCTAssertTrue(linked.isLinkedToMe, "Already-linked people come first so they can be undone.")
        XCTAssertEqual(linked.participantID, Fixture.participantA)
        for entry in entries {
            XCTAssertFalse(entry.projectName.isEmpty)
            XCTAssertFalse(entry.meetingTitle.isEmpty)
        }
    }

    func testTheDirectoryOrderIsStable() async throws {
        let service = try await makeService(projects: [Fixture.otherProject(), Fixture.project()])
        let first = try await service.directory().map(\.participantID)
        let second = try await service.directory().map(\.participantID)
        XCTAssertEqual(first, second)
    }

    // MARK: - Fixtures

    private enum Fixture {
        static let profileID = UUID(uuidString: "0000000F-0000-0000-0000-000000000001")!
        static let participantA = UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!
        static let participantB = UUID(uuidString: "0000000A-0000-0000-0000-000000000002")!
        static let participantC = UUID(uuidString: "0000000A-0000-0000-0000-000000000003")!
        static let participantD = UUID(uuidString: "0000000A-0000-0000-0000-000000000004")!
        static let projectOneID = UUID(uuidString: "0000000B-0000-0000-0000-000000000001")!
        static let projectTwoID = UUID(uuidString: "0000000B-0000-0000-0000-000000000002")!
        static let projectThreeID = UUID(uuidString: "0000000B-0000-0000-0000-000000000003")!

        static func project() -> Project {
            make(
                id: projectOneID,
                name: "출시 준비",
                participants: [
                    Participant(id: participantA, displayName: "서연", linkedUserID: nil, speakerLabel: nil),
                    Participant(id: participantB, displayName: "민준", linkedUserID: nil, speakerLabel: nil)
                ]
            )
        }

        static func otherProject() -> Project {
            make(
                id: projectTwoID,
                name: "고객 온보딩",
                participants: [
                    Participant(id: participantC, displayName: "서연", linkedUserID: nil, speakerLabel: nil)
                ]
            )
        }

        /// A different person who happens to share a name with someone in another meeting.
        static func sameNameProject() -> Project {
            make(
                id: projectThreeID,
                name: "다른 팀",
                participants: [
                    Participant(id: participantD, displayName: "서연", linkedUserID: nil, speakerLabel: nil)
                ]
            )
        }

        static func projectWithSpeakerResolution() -> Project {
            var project = self.project()
            project.meetings[0].speakerResolutions = [
                SpeakerResolution(
                    anonymousParticipantID: participantA,
                    providerSpeakerLabel: "A",
                    resolvedParticipantID: participantB
                )
            ]
            return project
        }

        static func actionItem(assignee: UUID?) -> ActionItem {
            ActionItem(
                id: UUID(),
                projectID: projectOneID,
                meetingID: projectOneID,
                title: "업무",
                details: nil,
                assigneeID: assignee,
                dueDate: nil,
                status: .confirmed,
                evidence: nil,
                confidence: Confidence(0.5),
                createdAt: LocalUserProfileTests.now,
                updatedAt: LocalUserProfileTests.now
            )
        }

        private static func make(id: UUID, name: String, participants: [Participant]) -> Project {
            let meeting = Meeting(
                id: id,
                projectID: id,
                title: "\(name) 회의",
                occurredAt: LocalUserProfileTests.now,
                sourceType: .pastedText,
                participants: participants,
                transcriptSegments: [],
                createdAt: LocalUserProfileTests.now
            )
            return Project(
                id: id,
                name: name,
                summary: "",
                createdAt: LocalUserProfileTests.now,
                updatedAt: LocalUserProfileTests.now,
                meetings: [meeting],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                nextAgenda: []
            )
        }
    }

    /// Re-reads a project through a fresh repository, to check nothing else was rewritten.
    private enum InMemoryProjectRepositoryHolder {
        static func reload(_ project: Project) async throws -> Project? {
            let repository = InMemoryProjectRepository()
            try await repository.save(project)
            return try await repository.project(id: project.id)
        }
    }
}

/// `XCTUnwrap` cannot be applied to an `await` expression directly without hoisting it first; this
/// keeps the call sites readable.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
