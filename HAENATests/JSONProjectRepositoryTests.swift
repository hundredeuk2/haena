import XCTest
@testable import HAENA

final class JSONProjectRepositoryTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        // A unique subdirectory under the system temp directory — never the real home
        // directory or Application Support — so tests can't collide or touch user data.
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-JSONProjectRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only ever remove the exact directory this test created.
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    private func fileURL(_ name: String = "projects.json") -> URL {
        testDirectory.appendingPathComponent(name)
    }

    private func makeProject(
        id: UUID = UUID(),
        name: String = "Project",
        createdAt: Date = TestFixtures.fixedDate
    ) -> Project {
        Project(
            id: id,
            name: name,
            summary: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    // MARK: - Initial loading

    func testLoadingReturnsEmptyListWhenFileDoesNotExist() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())

        let all = try await repository.allProjects()

        XCTAssertEqual(all, [])
    }

    func testLoadingParsesValidSchemaVersionFile() async throws {
        let project = makeProject(id: TestFixtures.projectID, name: "Existing Project")
        let store = ProjectStoreFile(schemaVersion: 1, projects: [project])
        try JSONEncoder().encode(store).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())
        let all = try await repository.allProjects()

        XCTAssertEqual(all, [project])
    }

    func testLoadingEmptyProjectsArray() async throws {
        let store = ProjectStoreFile(schemaVersion: 1, projects: [])
        try JSONEncoder().encode(store).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())
        let all = try await repository.allProjects()

        XCTAssertEqual(all, [])
    }

    func testLoadingRejectsUnsupportedSchemaVersion() async throws {
        let store = ProjectStoreFile(schemaVersion: 999, projects: [])
        try JSONEncoder().encode(store).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())

        do {
            _ = try await repository.allProjects()
            XCTFail("Expected unsupportedSchemaVersion")
        } catch JSONRepositoryError.unsupportedSchemaVersion(let found, let supported) {
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, ProjectStoreFile.currentSchemaVersion)
        }
    }

    func testLoadingCorruptJSONThrowsDecodingFailed() async throws {
        try Data("not valid json { { {".utf8).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())

        do {
            _ = try await repository.allProjects()
            XCTFail("Expected decodingFailed")
        } catch JSONRepositoryError.decodingFailed {
            // expected
        }
    }

    func testCorruptFileIsNotDeletedOrOverwrittenAfterFailedDecode() async throws {
        let corruptContent = "not valid json { { {"
        try Data(corruptContent.utf8).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())
        _ = try? await repository.allProjects()

        let contentOnDisk = try String(contentsOf: fileURL(), encoding: .utf8)
        XCTAssertEqual(contentOnDisk, corruptContent)
    }

    // MARK: - Saving

    func testSavingCreatesFile() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(makeProject(id: TestFixtures.projectID))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL().path))
    }

    func testSavedFileHasCurrentSchemaVersion() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(makeProject(id: TestFixtures.projectID))

        let data = try Data(contentsOf: fileURL())
        let store = try JSONDecoder().decode(ProjectStoreFile.self, from: data)

        XCTAssertEqual(store.schemaVersion, ProjectStoreFile.currentSchemaVersion)
    }

    func testSavedProjectIsInJSON() async throws {
        let project = makeProject(id: TestFixtures.projectID, name: "Saved Project")
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(project)

        let data = try Data(contentsOf: fileURL())
        let store = try JSONDecoder().decode(ProjectStoreFile.self, from: data)

        XCTAssertEqual(store.projects, [project])
    }

    func testSavingSameIDUpdatesWithoutDuplicate() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(makeProject(id: TestFixtures.projectID, name: "Original"))
        try await repository.save(makeProject(id: TestFixtures.projectID, name: "Renamed"))

        let all = try await repository.allProjects()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Renamed")
    }

    func testSavingMultipleProjects() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        let first = makeProject(name: "First")
        let second = makeProject(name: "Second")

        try await repository.save(first)
        try await repository.save(second)

        let all = try await repository.allProjects()
        XCTAssertEqual(Set(all.map(\.id)), Set([first.id, second.id]))
    }

    func testAllProjectsSortOrderIsCreatedAtAscending() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        let earliest = makeProject(name: "Earliest", createdAt: Date(timeIntervalSince1970: 1_000))
        let middle = makeProject(name: "Middle", createdAt: Date(timeIntervalSince1970: 2_000))
        let latest = makeProject(name: "Latest", createdAt: Date(timeIntervalSince1970: 3_000))

        // Saved out of chronological order on purpose.
        try await repository.save(latest)
        try await repository.save(earliest)
        try await repository.save(middle)

        let all = try await repository.allProjects()

        XCTAssertEqual(all.map(\.name), ["Earliest", "Middle", "Latest"])
    }

    func testReloadingWithNewRepositoryInstanceSeesPreviouslySavedData() async throws {
        let url = fileURL()
        let project = makeProject(id: TestFixtures.projectID, name: "Persisted Project")

        let firstRepository = JSONProjectRepository(fileURL: url)
        try await firstRepository.save(project)

        let secondRepository = JSONProjectRepository(fileURL: url)
        let all = try await secondRepository.allProjects()

        XCTAssertEqual(all, [project])
    }

    func testProjectAndTransitionApplyMarkerPersistAtomicallyAcrossRepositoryRestart() async throws {
        let url = fileURL()
        var project = makeProject(id: TestFixtures.projectID, name: "Before")
        project.name = "After"
        let marker = WorkStateTransitionApplyMarker(
            projectID: project.id,
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            operationKind: .proposal,
            intentHash: "opaque-intent-hash",
            appliedAt: TestFixtures.fixedDate
        )

        let writer = JSONProjectRepository(fileURL: url)
        try await writer.save(project, recording: marker)

        let restarted = JSONProjectRepository(fileURL: url)
        let reloadedProject = try await restarted.project(id: project.id)
        let reloadedMarker = try await restarted.transitionApplyMarker(
            projectID: project.id,
            operationID: marker.operationID,
            operationKind: marker.operationKind
        )
        XCTAssertEqual(reloadedProject, project)
        XCTAssertEqual(reloadedMarker, marker)
    }

    func testOrdinaryProjectSavePreservesExistingTransitionApplyMarker() async throws {
        let project = makeProject(id: TestFixtures.projectID, name: "Before")
        let marker = WorkStateTransitionApplyMarker(
            projectID: project.id,
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            operationKind: .ambiguity,
            intentHash: "opaque-intent-hash",
            appliedAt: TestFixtures.fixedDate
        )
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(project, recording: marker)
        var renamed = project
        renamed.name = "After"
        try await repository.save(renamed)

        let restarted = JSONProjectRepository(fileURL: fileURL())
        let preserved = try await restarted.transitionApplyMarker(
            projectID: project.id,
            operationID: marker.operationID,
            operationKind: marker.operationKind
        )
        XCTAssertEqual(preserved, marker)
    }

    func testLegacyProjectStoreLoadsWithoutTransitionApplyMarkers() async throws {
        let project = makeProject(id: TestFixtures.projectID)
        let legacy = """
        {"schemaVersion":1,"projects":\(String(data: try JSONEncoder().encode([project]), encoding: .utf8)!)}
        """
        try Data(legacy.utf8).write(to: fileURL())

        let repository = JSONProjectRepository(fileURL: fileURL())
        let loaded = try await repository.project(id: project.id)
        let marker = try await repository.transitionApplyMarker(
            projectID: project.id,
            operationID: UUID(),
            operationKind: .proposal
        )
        XCTAssertEqual(loaded, project)
        XCTAssertNil(marker)
    }

    // MARK: - Deletion

    func testDeletingRemovesProjectFromFile() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())
        try await repository.save(makeProject(id: TestFixtures.projectID))
        try await repository.delete(id: TestFixtures.projectID)

        let all = try await repository.allProjects()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeletionPersistsAcrossNewRepositoryInstance() async throws {
        let url = fileURL()
        let firstRepository = JSONProjectRepository(fileURL: url)
        try await firstRepository.save(makeProject(id: TestFixtures.projectID))
        try await firstRepository.delete(id: TestFixtures.projectID)

        let secondRepository = JSONProjectRepository(fileURL: url)
        let fetched = try await secondRepository.project(id: TestFixtures.projectID)

        XCTAssertNil(fetched)
    }

    func testDeletingNonexistentIDDoesNotThrow() async throws {
        let repository = JSONProjectRepository(fileURL: fileURL())

        try await repository.delete(id: UUID())
    }

    // MARK: - Pasted-text meeting integration

    func testTextMeetingRoundTripsThroughNewRepositoryInstance() async throws {
        let url = fileURL()

        let creationService = TextMeetingCaptureService(
            repository: JSONProjectRepository(fileURL: url),
            now: { TestFixtures.fixedDate },
            makeID: { TestFixtures.projectID }
        )
        let project = try await creationService.createProject(name: "Restored Project")

        let saveService = TextMeetingCaptureService(
            repository: JSONProjectRepository(fileURL: url),
            now: { TestFixtures.laterDate },
            makeID: { TestFixtures.meetingID }
        )
        _ = try await saveService.saveTextMeeting(
            projectID: project.id,
            title: "Restored Meeting",
            transcript: "Restored transcript body."
        )

        // A brand-new repository instance over the same file stands in for "app relaunched".
        let restoredRepository = JSONProjectRepository(fileURL: url)
        let fetchedProject = try await restoredRepository.project(id: project.id)
        let restoredProject = try XCTUnwrap(fetchedProject)

        XCTAssertEqual(restoredProject.meetings.count, 1)
        let restoredMeeting = try XCTUnwrap(restoredProject.meetings.first)
        XCTAssertEqual(restoredMeeting.title, "Restored Meeting")
        XCTAssertEqual(restoredMeeting.sourceType, .pastedText)

        XCTAssertEqual(restoredMeeting.transcriptSegments.count, 1)
        let restoredSegment = try XCTUnwrap(restoredMeeting.transcriptSegments.first)
        XCTAssertEqual(restoredSegment.text, "Restored transcript body.")
        XCTAssertNil(restoredSegment.startTime)
        XCTAssertNil(restoredSegment.endTime)
        XCTAssertNil(restoredSegment.speakerID)
    }

    // MARK: - Atomicity and failure

    func testDirectoryCreationFailureThrowsExplicitError() async throws {
        // Occupy the intended subdirectory path with a plain file instead of a directory, so
        // `createDirectory` fails deterministically — no OS permission manipulation involved.
        let occupiedPath = testDirectory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: occupiedPath)

        let repository = JSONProjectRepository(fileURL: occupiedPath.appendingPathComponent("projects.json"))

        do {
            try await repository.save(makeProject())
            XCTFail("Expected directoryCreationFailed")
        } catch JSONRepositoryError.directoryCreationFailed {
            // expected
        }
    }

    func testReadFailureThrowsExplicitErrorWhenDestinationIsADirectory() async throws {
        // The destination path itself is pre-occupied by a directory. `save` loads existing
        // state first, and reading a directory's contents as `Data` fails deterministically —
        // no permission manipulation involved, and this exercises the same "explicit typed
        // error, never silent" contract as a write failure would.
        let url = fileURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let repository = JSONProjectRepository(fileURL: url)

        do {
            try await repository.save(makeProject())
            XCTFail("Expected readFailed")
        } catch JSONRepositoryError.readFailed {
            // expected
        }
    }
}
