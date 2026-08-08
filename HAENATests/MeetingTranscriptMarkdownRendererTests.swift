import XCTest
@testable import HAENA

/// Covers the transcript document itself: that it says what was said, attributes it to whoever the
/// user confirmed, and adds nothing.
final class MeetingTranscriptMarkdownRendererTests: XCTestCase {
    private static let speakerOneID = UUID(uuidString: "44444444-0000-0000-0000-000000000001")!
    private static let speakerTwoID = UUID(uuidString: "44444444-0000-0000-0000-000000000002")!
    private static let speakerThreeID = UUID(uuidString: "44444444-0000-0000-0000-000000000003")!
    private static let patrickID = UUID(uuidString: "44444444-0000-0000-0000-0000000000AA")!
    private static let minsuID = UUID(uuidString: "44444444-0000-0000-0000-0000000000BB")!

    /// Pinned so assertions do not depend on the machine's locale or time zone.
    private let renderer = MeetingTranscriptMarkdownRenderer(
        dateFormatter: MeetingDateFormatter(
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(identifier: "Asia/Seoul")!
        )
    )

    // MARK: - Fixtures

    private static func speaker(_ id: UUID, _ name: String, label: String?) -> Participant {
        Participant(id: id, displayName: name, linkedUserID: nil, speakerLabel: label)
    }

    private static func segment(
        _ text: String,
        speakerID: UUID?,
        start: TimeInterval?,
        end: TimeInterval?
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            meetingID: TestFixtures.meetingID,
            speakerID: speakerID,
            text: text,
            startTime: start,
            endTime: end
        )
    }

    private static func meeting(
        title: String = "제품 점검 회의",
        sourceType: MeetingSourceType = .audioFile,
        participants: [Participant],
        segments: [TranscriptSegment],
        resolutions: [SpeakerResolution] = []
    ) -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: title,
            occurredAt: TestFixtures.fixedDate,
            sourceType: sourceType,
            participants: participants,
            transcriptSegments: segments,
            createdAt: TestFixtures.fixedDate,
            speakerResolutions: resolutions
        )
    }

    /// Three voices: two confirmed as different people, one left anonymous.
    private static func mixedMeeting() -> Meeting {
        meeting(
            participants: [
                speaker(speakerOneID, "Speaker 1", label: "A"),
                speaker(speakerTwoID, "Speaker 2", label: "B"),
                speaker(speakerThreeID, "Speaker 3", label: "C"),
                speaker(patrickID, "Patrick", label: nil),
                speaker(minsuID, "민수", label: nil)
            ],
            segments: [
                segment("오늘 배포 일정을 먼저 확인하겠습니다.", speakerID: speakerOneID, start: 3, end: 11),
                segment("API 연결은 오늘 마무리하겠습니다.", speakerID: speakerTwoID, start: 12, end: 19),
                segment("이 발언에는 타임스탬프가 없습니다.", speakerID: speakerThreeID, start: nil, end: nil)
            ],
            resolutions: [
                SpeakerResolution(
                    anonymousParticipantID: speakerOneID,
                    providerSpeakerLabel: "A",
                    resolvedParticipantID: patrickID
                ),
                SpeakerResolution(
                    anonymousParticipantID: speakerTwoID,
                    providerSpeakerLabel: "B",
                    resolvedParticipantID: minsuID
                )
            ]
        )
    }

    // MARK: - Header

    func testHeaderCarriesTitleDateAndSourceType() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        let lines = markdown.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "# 제품 점검 회의")
        XCTAssertTrue(markdown.contains("- 일시: "))
        XCTAssertTrue(markdown.contains("- 입력 방식: 음성 파일"))
    }

    /// Confirmed voices collapse into people; the unconfirmed one keeps its anonymous name.
    func testAttendeeListUsesConfirmedNamesAndKeepsAnonymousOnes() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        XCTAssertTrue(markdown.contains("- 참석자: Patrick, 민수, Speaker 3"))
    }

    func testAttendeeLineIsOmittedWhenThereAreNoSpeakers() {
        let textMeeting = Self.meeting(
            title: "붙여넣은 회의",
            sourceType: .pastedText,
            participants: [],
            segments: [Self.segment("붙여넣은 본문입니다.", speakerID: nil, start: nil, end: nil)]
        )
        XCTAssertFalse(renderer.render(meeting: textMeeting).contains("참석자"))
    }

    // MARK: - Speaker resolution

    func testConfirmedSpeakersPrintTheirRealNames() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        XCTAssertTrue(markdown.contains("[00:03–00:11] Patrick"))
        XCTAssertTrue(markdown.contains("[00:12–00:19] 민수"))
    }

    /// The export shows `Speaker N` rather than the provider's raw label, which is what makes a
    /// shared document readable.
    func testUnconfirmedSpeakerKeepsItsAnonymousName() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        XCTAssertTrue(markdown.contains("[시간 없음] Speaker 3"))
        XCTAssertFalse(markdown.contains("] C\n"), "The provider label must not appear as a speaker name.")
    }

    func testTwoVoicesConfirmedAsOnePersonBothPrintThatName() {
        let merged = Self.meeting(
            participants: [
                Self.speaker(Self.speakerOneID, "Speaker 1", label: "A"),
                Self.speaker(Self.speakerTwoID, "Speaker 2", label: "B"),
                Self.speaker(Self.patrickID, "Patrick", label: nil)
            ],
            segments: [
                Self.segment("첫 번째 발언입니다.", speakerID: Self.speakerOneID, start: 0, end: 4),
                Self.segment("두 번째 발언입니다.", speakerID: Self.speakerTwoID, start: 4, end: 8)
            ],
            resolutions: [
                SpeakerResolution(
                    anonymousParticipantID: Self.speakerOneID,
                    providerSpeakerLabel: "A",
                    resolvedParticipantID: Self.patrickID
                ),
                SpeakerResolution(
                    anonymousParticipantID: Self.speakerTwoID,
                    providerSpeakerLabel: "B",
                    resolvedParticipantID: Self.patrickID
                )
            ]
        )
        let markdown = renderer.render(meeting: merged)

        XCTAssertTrue(markdown.contains("[00:00–00:04] Patrick"))
        XCTAssertTrue(markdown.contains("[00:04–00:08] Patrick"))
        XCTAssertFalse(markdown.contains("Speaker 1"))
        XCTAssertFalse(markdown.contains("Speaker 2"))
        XCTAssertEqual(markdown.components(separatedBy: "- 참석자: Patrick\n").count, 2, "Listed once.")
    }

    func testSegmentWithoutASpeakerIsAttributedToNobody() {
        let anonymous = Self.meeting(
            sourceType: .pastedText,
            participants: [],
            segments: [Self.segment("화자 정보가 없는 발언.", speakerID: nil, start: 5, end: 9)]
        )
        XCTAssertTrue(renderer.render(meeting: anonymous).contains("[00:05–00:09] 화자 미상"))
    }

    /// Resolutions live inside the meeting, so a sibling meeting's confirmations cannot apply here.
    func testAnotherMeetingsResolutionDoesNotAffectThisDocument() {
        var unconfirmed = Self.mixedMeeting()
        unconfirmed.speakerResolutions = []
        let markdown = renderer.render(meeting: unconfirmed)

        XCTAssertTrue(markdown.contains("Speaker 1"))
        XCTAssertFalse(markdown.contains("Patrick"), "An unconfirmed meeting must not borrow a name.")
    }

    // MARK: - Timestamps

    func testStartOnlySegmentShowsOnlyTheStart() {
        let partial = Self.meeting(
            participants: [Self.speaker(Self.speakerOneID, "Speaker 1", label: "A")],
            segments: [Self.segment("끝 시간이 없습니다.", speakerID: Self.speakerOneID, start: 7, end: nil)]
        )
        let markdown = renderer.render(meeting: partial)
        XCTAssertTrue(markdown.contains("[00:07] Speaker 1"))
        XCTAssertFalse(markdown.contains("–"))
    }

    /// A meeting longer than an hour must not wrap round to `00:xx`.
    func testTimestampsBeyondAnHourUseHoursMinutesSeconds() {
        let long = Self.meeting(
            participants: [Self.speaker(Self.speakerOneID, "Speaker 1", label: "A")],
            segments: [
                Self.segment("한 시간이 지난 발언.", speakerID: Self.speakerOneID, start: 3_661, end: 3_725)
            ]
        )
        XCTAssertTrue(renderer.render(meeting: long).contains("[01:01:01–01:02:05] Speaker 1"))
    }

    func testMissingTimestampsAreStatedNotFabricated() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        XCTAssertTrue(markdown.contains("[시간 없음]"))
        XCTAssertFalse(markdown.contains("[00:00] Speaker 3"), "A missing time must not become 00:00.")
    }

    // MARK: - Body

    func testSegmentsKeepTheirStoredOrder() {
        let markdown = renderer.render(meeting: Self.mixedMeeting())
        let first = try? XCTUnwrap(markdown.range(of: "오늘 배포 일정을 먼저 확인하겠습니다."))
        let second = try? XCTUnwrap(markdown.range(of: "API 연결은 오늘 마무리하겠습니다."))
        let third = try? XCTUnwrap(markdown.range(of: "이 발언에는 타임스탬프가 없습니다."))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
        if let first, let second, let third {
            XCTAssertTrue(first.lowerBound < second.lowerBound)
            XCTAssertTrue(second.lowerBound < third.lowerBound)
        }
    }

    func testBlankSegmentsAreOmitted() {
        let withBlanks = Self.meeting(
            participants: [Self.speaker(Self.speakerOneID, "Speaker 1", label: "A")],
            segments: [
                Self.segment("실제 발언입니다.", speakerID: Self.speakerOneID, start: 0, end: 3),
                Self.segment("", speakerID: Self.speakerOneID, start: 3, end: 4),
                Self.segment("   ", speakerID: Self.speakerOneID, start: 4, end: 5)
            ]
        )
        let markdown = renderer.render(meeting: withBlanks)

        XCTAssertEqual(
            markdown.components(separatedBy: "] Speaker 1").count - 1,
            1,
            "Only the one segment with speech may appear."
        )
        XCTAssertFalse(markdown.contains("[00:03–00:04]"))
    }

    func testWhollyEmptyTranscriptStatesTheAbsence() {
        let empty = Self.meeting(
            participants: [],
            segments: [Self.segment("   ", speakerID: nil, start: nil, end: nil)]
        )
        let markdown = renderer.render(meeting: empty)

        XCTAssertTrue(markdown.contains("## 전사"))
        XCTAssertTrue(markdown.contains("전사 내용이 없습니다."))
        XCTAssertFalse(MeetingTranscriptMarkdownRenderer.hasExportableContent(empty))
    }

    func testHasExportableContentIsTrueWhenAnySegmentHasText() {
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(Self.mixedMeeting()))
    }

    /// Verbatim means verbatim: Korean, English, and Markdown syntax all survive unaltered,
    /// because escaping would put characters into the record that nobody said.
    func testTranscriptTextIsPreservedExactly() {
        let tricky = "**중요** 그 API_KEY는 `config.yaml`에 있고 [링크](http://x) 처럼 씁니다 — 100% 확인!"
        let meeting = Self.meeting(
            participants: [Self.speaker(Self.speakerOneID, "Speaker 1", label: "A")],
            segments: [Self.segment(tricky, speakerID: Self.speakerOneID, start: 0, end: 5)]
        )
        let markdown = renderer.render(meeting: meeting)

        XCTAssertTrue(markdown.contains(tricky), "The utterance must appear byte-for-byte.")
        XCTAssertFalse(markdown.contains("\\*"), "Escaping would alter what was said.")
    }

    // MARK: - What must never be included

    func testDocumentExcludesWorkStateAndInternals() {
        var meeting = Self.mixedMeeting()
        meeting.audioAsset = AudioAsset(
            id: UUID(),
            storedFileName: "F0000000-0000-0000-0000-000000000001.m4a",
            originalFileName: "비밀회의녹음.m4a",
            byteSize: 1024,
            importedAt: TestFixtures.fixedDate
        )
        let markdown = renderer.render(meeting: meeting)

        XCTAssertFalse(markdown.contains(".m4a"), "No audio path may appear.")
        XCTAssertFalse(markdown.contains("비밀회의녹음"))
        XCTAssertFalse(markdown.contains(TestFixtures.meetingID.uuidString), "No identifiers.")
        XCTAssertFalse(markdown.contains("결정"))
        XCTAssertFalse(markdown.contains("업무"))
        XCTAssertFalse(markdown.contains("확신도"))
    }

    // MARK: - Filename

    func testFilenameIsBasedOnTheTitleAndSanitized() {
        let awkward = Self.meeting(
            title: "2026/08 제품: 점검*회의?",
            participants: [],
            segments: [Self.segment("본문", speakerID: nil, start: nil, end: nil)]
        )
        let filename = MeetingTranscriptMarkdownRenderer.filename(for: awkward)

        XCTAssertTrue(filename.hasSuffix(".md"))
        for forbidden in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            XCTAssertFalse(filename.contains(forbidden), "\(forbidden) must not survive into a filename.")
        }
        XCTAssertTrue(filename.contains("전사"), "A transcript stays distinguishable from a status export.")
    }

    func testFilenameSurvivesATitleThatSanitizesToNothing() {
        let blank = Self.meeting(
            title: "///",
            participants: [],
            segments: [Self.segment("본문", speakerID: nil, start: nil, end: nil)]
        )
        let filename = MeetingTranscriptMarkdownRenderer.filename(for: blank)
        XCTAssertFalse(filename.hasPrefix("."))
        XCTAssertTrue(filename.hasSuffix(".md"))
    }
}
