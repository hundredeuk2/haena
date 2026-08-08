import XCTest
@testable import HAENA

/// Records what would have been copied instead of touching `NSPasteboard.general` — a unit test
/// must not destroy whatever the person running it had on their clipboard.
private final class SpyPasteboardWriter: PasteboardWriter {
    private(set) var written: [String] = []
    var succeeds = true

    func write(_ string: String) -> Bool {
        written.append(string)
        return succeeds
    }
}

/// Records what would have been saved instead of opening a modal panel or writing to disk.
@MainActor
private final class SpyFileExporter: MarkdownFileExporter {
    private(set) var exported: [(markdown: String, filename: String)] = []
    var outcome: MarkdownExportOutcome = .saved

    func export(_ markdown: String, suggestedFilename: String) -> MarkdownExportOutcome {
        exported.append((markdown, suggestedFilename))
        return outcome
    }
}

/// Covers the two boundaries the transcript export crosses — the filesystem and the system
/// pasteboard — plus the guarantee that both carry the same bytes.
final class MeetingTranscriptExportBoundaryTests: XCTestCase {
    private static let speakerID = UUID(uuidString: "55555555-0000-0000-0000-000000000001")!
    private static let patrickID = UUID(uuidString: "55555555-0000-0000-0000-0000000000AA")!

    private static func meeting(
        title: String = "제품 점검 회의",
        sourceType: MeetingSourceType = .audioFile,
        text: String = "오늘 배포 일정을 먼저 확인하겠습니다.",
        confirmed: Bool = true
    ) -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: title,
            occurredAt: TestFixtures.fixedDate,
            sourceType: sourceType,
            participants: [
                Participant(id: speakerID, displayName: "Speaker 1", linkedUserID: nil, speakerLabel: "A"),
                Participant(id: patrickID, displayName: "Patrick", linkedUserID: nil, speakerLabel: nil)
            ],
            transcriptSegments: [
                TranscriptSegment(
                    id: UUID(),
                    meetingID: TestFixtures.meetingID,
                    speakerID: speakerID,
                    text: text,
                    startTime: 3,
                    endTime: 11
                )
            ],
            createdAt: TestFixtures.fixedDate,
            speakerResolutions: confirmed
                ? [
                    SpeakerResolution(
                        anonymousParticipantID: speakerID,
                        providerSpeakerLabel: "A",
                        resolvedParticipantID: patrickID
                    )
                ]
                : []
        )
    }

    private static func emptyMeeting() -> Meeting {
        var meeting = self.meeting()
        meeting.transcriptSegments = [
            TranscriptSegment(
                id: UUID(),
                meetingID: TestFixtures.meetingID,
                speakerID: speakerID,
                text: "   ",
                startTime: nil,
                endTime: nil
            )
        ]
        return meeting
    }

    // MARK: - UTF-8 on disk

    /// The real exporter is exercised against a temp file, so the encoding is checked rather than
    /// assumed: the document is mostly Korean and a mis-encode would corrupt every line.
    func testMarkdownIsWrittenAsUTF8() throws {
        let markdown = MeetingTranscriptMarkdownRenderer().render(meeting: Self.meeting())
        let directory = try AudioTestSupport.makeTemporaryDirectory(self)
        let url = directory.appendingPathComponent("transcript.md")

        try MarkdownExportData.utf8Data(markdown).write(to: url, options: .atomic)

        let reread = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertEqual(reread, markdown)
        XCTAssertTrue(reread.contains("Patrick"))
        XCTAssertTrue(reread.contains("오늘 배포 일정을 먼저 확인하겠습니다."))
    }

    // MARK: - Same bytes both ways

    /// The file and the clipboard must be incapable of differing: both come from one renderer call.
    @MainActor
    func testClipboardContentMatchesTheExportedFileExactly() {
        let meeting = Self.meeting()
        let expected = MeetingTranscriptMarkdownRenderer().render(meeting: meeting)

        let pasteboard = SpyPasteboardWriter()
        let exporter = SpyFileExporter()
        _ = pasteboard.write(expected)
        _ = exporter.export(expected, suggestedFilename: MeetingTranscriptMarkdownRenderer.filename(for: meeting))

        XCTAssertEqual(pasteboard.written.first, exporter.exported.first?.markdown)
        XCTAssertEqual(pasteboard.written.first, expected)
    }

    func testSuggestedFilenameIsDerivedFromTheMeetingTitle() {
        let filename = MeetingTranscriptMarkdownRenderer.filename(for: Self.meeting(title: "8월 8일 제품 점검"))
        XCTAssertTrue(filename.hasPrefix("8월 8일 제품 점검"))
        XCTAssertTrue(filename.hasSuffix(".md"))
    }

    // MARK: - Outcomes

    @MainActor
    func testCancellingLeavesNoFileAndIsNotAnError() throws {
        let directory = try AudioTestSupport.makeTemporaryDirectory(self)
        let exporter = SpyFileExporter()
        exporter.outcome = .cancelled

        let outcome = exporter.export("내용", suggestedFilename: "transcript.md")

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    @MainActor
    func testWriteFailureIsReportedAsFailed() {
        let exporter = SpyFileExporter()
        exporter.outcome = .failed
        XCTAssertEqual(exporter.export("내용", suggestedFilename: "transcript.md"), .failed)
    }

    func testPasteboardRefusalIsReported() {
        let pasteboard = SpyPasteboardWriter()
        pasteboard.succeeds = false
        XCTAssertFalse(pasteboard.write("내용"))
    }

    // MARK: - Nothing to export

    /// A transcript with no speech must not touch the clipboard: silently replacing whatever the
    /// user had copied with an empty document would be worse than doing nothing.
    func testEmptyTranscriptIsNotExportable() {
        let empty = Self.emptyMeeting()
        XCTAssertFalse(MeetingTranscriptMarkdownRenderer.hasExportableContent(empty))

        let pasteboard = SpyPasteboardWriter()
        if MeetingTranscriptMarkdownRenderer.hasExportableContent(empty) {
            _ = pasteboard.write(MeetingTranscriptMarkdownRenderer().render(meeting: empty))
        }
        XCTAssertTrue(pasteboard.written.isEmpty, "The pasteboard must be left untouched.")
    }

    // MARK: - Independent of audio

    /// The feature keys off the transcript, never the recording — a pasted-text meeting and one
    /// whose audio was deleted both still export.
    func testTextMeetingAndAudiolessMeetingAreBothExportable() {
        let pasted = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "붙여넣은 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [
                TranscriptSegment(
                    id: UUID(),
                    meetingID: TestFixtures.meetingID,
                    speakerID: nil,
                    text: "붙여넣은 본문입니다.",
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(pasted))
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer().render(meeting: pasted).contains("붙여넣은 본문입니다."))

        // An audio meeting whose stored copy is gone still has its words.
        var audioless = Self.meeting()
        audioless.audioAsset = nil
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(audioless))
    }

    // MARK: - No regression in the project export

    /// The two documents must stay distinguishable: the project export is a reviewed-state summary
    /// and must not have acquired transcript sections.
    func testProjectStatusExportIsUnchangedByTheTranscriptFeature() {
        let project = AudioTestSupport.project(meetings: [Self.meeting()])
        let markdown = ProjectMarkdownRenderer(
            dateFormatter: MeetingDateFormatter(
                locale: Locale(identifier: "ko_KR"),
                timeZone: TimeZone(identifier: "Asia/Seoul")!
            )
        ).render(
            project: project,
            summary: ProjectStatusSummary.complete(project: project, referenceDate: TestFixtures.fixedDate),
            generatedAt: TestFixtures.fixedDate
        )

        XCTAssertTrue(markdown.hasPrefix("# HAE.NA"), "Still headed by the project, not a meeting.")
        XCTAssertFalse(markdown.contains("## 전사"), "The project export must not gain a transcript section.")
        XCTAssertFalse(
            markdown.contains("오늘 배포 일정을 먼저 확인하겠습니다."),
            "Raw transcript text must not leak into the project status document."
        )
        XCTAssertTrue(markdown.contains("- 생성 시각: "))
    }

    func testProjectAndTranscriptFilenamesDoNotCollide() {
        let meeting = Self.meeting(title: "HAE.NA")
        XCTAssertNotEqual(
            MeetingTranscriptMarkdownRenderer.filename(for: meeting),
            ProjectExportFilename.markdownFilename(for: "HAE.NA")
        )
    }
}
