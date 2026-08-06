import XCTest
@testable import HAENA

final class AudioAssetStoreTests: XCTestCase {
    private var sourceDirectory: URL!
    private var storeDirectory: URL!
    private var store: AudioAssetStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        storeDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        store = AudioAssetStore(directoryURL: storeDirectory.appendingPathComponent("Audio", isDirectory: true))
    }

    private func validatedFile(named name: String, byteCount: Int = 256) throws -> ValidatedAudioFile {
        let url = try AudioTestSupport.writeFile(named: name, byteCount: byteCount, in: sourceDirectory)
        return try AudioFileValidator().validate(url)
    }

    // MARK: - Copying

    func testStoreCopiesFileAndCreatesItsDirectory() throws {
        let file = try validatedFile(named: "meeting.m4a")
        let asset = try store.store(file, id: TestFixtures.meetingID, importedAt: TestFixtures.fixedDate)

        XCTAssertEqual(asset.originalFileName, "meeting.m4a")
        XCTAssertEqual(asset.byteSize, 256)
        XCTAssertEqual(asset.importedAt, TestFixtures.fixedDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: asset).path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: asset)).count, 256)
    }

    /// The provider infers the container format from the multipart filename, so the extension has
    /// to survive the copy.
    func testStoredNameIsUUIDBasedAndKeepsTheExtension() throws {
        let file = try validatedFile(named: "회의 녹음.m4a")
        let asset = try store.store(file, id: TestFixtures.meetingID, importedAt: TestFixtures.fixedDate)

        XCTAssertEqual(asset.storedFileName, "\(TestFixtures.meetingID.uuidString).m4a")
        XCTAssertFalse(asset.storedFileName.contains("회의"))
    }

    /// Two different recordings both called `meeting.m4a` is the ordinary case, not an edge case.
    func testTwoFilesWithTheSameNameDoNotCollide() throws {
        let first = try validatedFile(named: "meeting.m4a", byteCount: 100)
        let firstAsset = try store.store(first, id: UUID(), importedAt: TestFixtures.fixedDate)

        try FileManager.default.removeItem(at: first.url)
        let second = try validatedFile(named: "meeting.m4a", byteCount: 200)
        let secondAsset = try store.store(second, id: UUID(), importedAt: TestFixtures.fixedDate)

        XCTAssertNotEqual(firstAsset.storedFileName, secondAsset.storedFileName)
        XCTAssertEqual(try Data(contentsOf: store.url(for: firstAsset)).count, 100)
        XCTAssertEqual(try Data(contentsOf: store.url(for: secondAsset)).count, 200)
    }

    /// The whole reason the copy exists: the user's original is theirs to move or delete.
    func testCopySurvivesDeletionOfTheOriginal() throws {
        let file = try validatedFile(named: "meeting.wav")
        let asset = try store.store(file, id: UUID(), importedAt: TestFixtures.fixedDate)

        try FileManager.default.removeItem(at: file.url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: asset).path))
    }

    /// `storedFileName` is a bare name, so an asset decoded from disk must still resolve through
    /// a freshly constructed store pointed at the same directory.
    func testAssetResolvesThroughANewStoreInstance() throws {
        let file = try validatedFile(named: "meeting.mp3")
        let asset = try store.store(file, id: UUID(), importedAt: TestFixtures.fixedDate)

        let reencoded = try JSONDecoder().decode(AudioAsset.self, from: JSONEncoder().encode(asset))
        let reopened = AudioAssetStore(
            directoryURL: storeDirectory.appendingPathComponent("Audio", isDirectory: true)
        )

        XCTAssertEqual(reencoded, asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.url(for: reencoded).path))
    }

    // MARK: - Removal

    func testRemoveDeletesTheStoredCopy() throws {
        let file = try validatedFile(named: "meeting.m4a")
        let asset = try store.store(file, id: UUID(), importedAt: TestFixtures.fixedDate)

        store.remove(asset)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: asset).path))
    }

    /// Removal is best-effort: a missing file must not become an error that aborts a deletion the
    /// user already asked for.
    func testRemovingAnAlreadyMissingAssetIsNotAnError() {
        let asset = AudioAsset(
            id: UUID(),
            storedFileName: "absent.m4a",
            originalFileName: "absent.m4a",
            byteSize: 1,
            importedAt: TestFixtures.fixedDate
        )
        store.remove(asset)
    }
}
