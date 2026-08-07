import XCTest
@testable import HAENA

/// Every rejection path runs against a real file on disk, because the point of validation is to
/// agree with what the filesystem and the provider actually do.
final class AudioFileValidatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try AudioTestSupport.makeTemporaryDirectory(self)
    }

    // MARK: - Formats

    func testAcceptsEverySupportedExtension() throws {
        let validator = AudioFileValidator()
        for fileExtension in AudioFileValidator.supportedExtensions {
            let url = try AudioTestSupport.writeFile(
                named: "meeting.\(fileExtension)",
                byteCount: 128,
                in: directory
            )
            let validated = try validator.validate(url)
            XCTAssertEqual(validated.fileName, "meeting.\(fileExtension)")
            XCTAssertEqual(validated.byteSize, 128)
        }
    }

    func testAcceptsUppercaseExtension() throws {
        let url = try AudioTestSupport.writeFile(named: "MEETING.M4A", byteCount: 64, in: directory)
        XCTAssertEqual(try AudioFileValidator().validate(url).byteSize, 64)
    }

    func testRejectsUnsupportedExtension() throws {
        let url = try AudioTestSupport.writeFile(named: "meeting.aiff", byteCount: 128, in: directory)
        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(
                error as? AudioFileValidationError,
                .unsupportedFormat(fileExtension: "aiff")
            )
        }
    }

    func testRejectsFileWithNoExtension() throws {
        let url = try AudioTestSupport.writeFile(named: "meeting", byteCount: 128, in: directory)
        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(error as? AudioFileValidationError, .unsupportedFormat(fileExtension: ""))
        }
    }

    // MARK: - Existence

    func testRejectsMissingFile() {
        let url = directory.appendingPathComponent("absent.m4a")
        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(error as? AudioFileValidationError, .fileNotFound)
        }
    }

    /// A directory named `something.m4a` is a real possibility on macOS (bundles), and must not
    /// be treated as a file that merely failed to read.
    func testRejectsDirectoryWithAudioExtension() throws {
        let url = directory.appendingPathComponent("bundle.m4a", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(error as? AudioFileValidationError, .fileNotFound)
        }
    }

    // MARK: - Size

    func testRejectsEmptyFile() throws {
        let url = try AudioTestSupport.writeFile(named: "empty.wav", byteCount: 0, in: directory)
        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(error as? AudioFileValidationError, .emptyFile)
        }
    }

    /// The boundary is asserted with a small injected limit rather than by writing a real 25 MB
    /// file: the comparison being tested is `<=` vs `<`, and a 25 MB write would slow the suite
    /// down for no extra coverage.
    func testAcceptsFileExactlyAtTheLimit() throws {
        let url = try AudioTestSupport.writeFile(named: "exact.m4a", byteCount: 1_000, in: directory)
        let validated = try AudioFileValidator(maximumFileBytes: 1_000).validate(url)
        XCTAssertEqual(validated.byteSize, 1_000)
    }

    func testRejectsFileOneByteOverTheLimit() throws {
        let url = try AudioTestSupport.writeFile(named: "over.m4a", byteCount: 1_001, in: directory)
        XCTAssertThrowsError(try AudioFileValidator(maximumFileBytes: 1_000).validate(url)) { error in
            XCTAssertEqual(
                error as? AudioFileValidationError,
                .fileTooLarge(byteSize: 1_001, limit: 1_000)
            )
        }
    }

    /// The shipped default must be OpenAI's published ceiling, not a number that drifted.
    func testDefaultLimitIs25MB() {
        XCTAssertEqual(AudioFileValidator.maximumFileBytes, 26_214_400)
    }

    // MARK: - Readability

    func testRejectsUnreadableFile() throws {
        let url = try AudioTestSupport.writeFile(named: "locked.wav", byteCount: 128, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        // Running as root would make the file readable regardless, which would make this a
        // false pass rather than a real check.
        try XCTSkipIf(getuid() == 0, "Permission checks are meaningless as root.")

        XCTAssertThrowsError(try AudioFileValidator().validate(url)) { error in
            XCTAssertEqual(error as? AudioFileValidationError, .notReadable)
        }
    }
}
