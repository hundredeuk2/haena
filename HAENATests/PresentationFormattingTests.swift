import XCTest
@testable import HAENA

final class PresentationFormattingTests: XCTestCase {
    // MARK: - MeetingSourceTypeDisplay

    func testMeetingSourceTypeDisplayLabelsForAllCases() {
        XCTAssertEqual(MeetingSourceTypeDisplay.label(for: .microphone), "마이크 녹음")
        XCTAssertEqual(MeetingSourceTypeDisplay.label(for: .audioFile), "음성 파일")
        XCTAssertEqual(MeetingSourceTypeDisplay.label(for: .videoFile), "영상 파일")
        XCTAssertEqual(MeetingSourceTypeDisplay.label(for: .pastedText), "텍스트 입력")
    }

    // MARK: - MeetingCountDisplay

    func testMeetingCountDisplayLabel() {
        XCTAssertEqual(MeetingCountDisplay.label(count: 0), "회의 0개")
        XCTAssertEqual(MeetingCountDisplay.label(count: 3), "회의 3개")
    }

    // MARK: - TranscriptSpeakerDisplay

    func testTranscriptSpeakerDisplayWithoutSpeaker() {
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Meeting",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: nil,
            text: "본문",
            startTime: nil,
            endTime: nil
        )

        XCTAssertNil(TranscriptSpeakerDisplay.label(for: segment, in: meeting))
    }

    func testTranscriptSpeakerDisplayWithSpeaker() {
        let participant = Participant(
            id: TestFixtures.participantID,
            displayName: "Kim",
            linkedUserID: nil,
            speakerLabel: "Speaker 1"
        )
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Meeting",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .microphone,
            participants: [participant],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: TestFixtures.participantID,
            text: "본문",
            startTime: 5,
            endTime: 10
        )

        XCTAssertEqual(TranscriptSpeakerDisplay.label(for: segment, in: meeting), "Speaker 1")
    }

    func testTranscriptSpeakerDisplayFallsBackToDisplayNameWithoutLabel() {
        let participant = Participant(
            id: TestFixtures.participantID,
            displayName: "Kim",
            linkedUserID: nil,
            speakerLabel: nil
        )
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Meeting",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .microphone,
            participants: [participant],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: TestFixtures.participantID,
            text: "본문",
            startTime: nil,
            endTime: nil
        )

        XCTAssertEqual(TranscriptSpeakerDisplay.label(for: segment, in: meeting), "Kim")
    }

    // MARK: - TranscriptTimestampFormatter

    func testTranscriptTimestampFormatsSecondsUnderAnHour() {
        XCTAssertEqual(TranscriptTimestampFormatter.string(from: 42), "00:42")
        XCTAssertEqual(TranscriptTimestampFormatter.string(from: 65), "01:05")
    }

    func testTranscriptTimestampFormatsOverAnHour() {
        XCTAssertEqual(TranscriptTimestampFormatter.string(from: 3_913), "01:05:13")
    }

    func testTranscriptTimestampReturnsNilForNilInput() {
        XCTAssertNil(TranscriptTimestampFormatter.string(from: nil))
    }

    func testTranscriptTimestampReturnsNilForNegativeInput() {
        XCTAssertNil(TranscriptTimestampFormatter.string(from: -1))
    }

    // MARK: - MeetingDateFormatter

    func testDateFormatterProducesDeterministicResultForFixedLocaleAndTimeZone() {
        // Exact ICU whitespace around AM/PM varies by OS version, so this asserts determinism
        // (same locale/timeZone + same Date -> identical output every time) and the presence
        // of the expected date/time components, rather than a brittle hardcoded full string.
        let formatter = MeetingDateFormatter(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        // 2023-11-14 22:13:20 UTC
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = formatter.string(from: date)
        let second = formatter.string(from: date)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("Nov 14, 2023"))
        XCTAssertTrue(first.contains("10:13"))
    }
}
