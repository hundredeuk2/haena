import Foundation

/// Renders one meeting's stored transcript as Markdown, for reading outside the app or pasting
/// into a message.
///
/// Pure by construction: it reads only a `Meeting` and formatters passed in — no repository, no
/// view, no provider — so the same meeting always produces the same document.
///
/// Deliberately **not** part of `ProjectMarkdownRenderer`. That document is the reviewed state of
/// a project: decisions somebody approved, work somebody owns. This one is the opposite — the raw
/// words that were said, with nothing added. Folding transcript rules into it would blur two
/// documents whose whole value is that a reader knows which one they are holding.
///
/// What it leaves out matters as much as what it includes: no AI proposal, decision, or action
/// item appears here, and neither does anything internal — no identifiers, no audio path, no
/// provider or key configuration. Transcript text is copied verbatim, never summarised,
/// corrected, translated, or escaped, because the point of a transcript is that it is what was
/// actually said.
struct MeetingTranscriptMarkdownRenderer {
    private let dateFormatter: MeetingDateFormatter

    init(dateFormatter: MeetingDateFormatter = MeetingDateFormatter()) {
        self.dateFormatter = dateFormatter
    }

    /// Shown in place of a speaker name when the provider attributed a segment to nobody. A real
    /// state, not a failure — pasted-text meetings have no speakers at all.
    private static let unknownSpeakerLabel = "화자 미상"

    /// Whether there is anything worth exporting. Callers use this to disable the actions rather
    /// than write a document with an empty body.
    static func hasExportableContent(_ meeting: Meeting) -> Bool {
        meeting.transcriptSegments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func render(meeting: Meeting) -> String {
        var lines: [String] = []

        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("- 일시: \(dateFormatter.string(from: meeting.occurredAt))")
        lines.append("- 입력 방식: \(MeetingSourceTypeDisplay.label(for: meeting.sourceType))")
        // Confirmed voices collapse into the person they belong to, so somebody identified as two
        // separate voices is listed once. Omitted entirely when there are no speakers, rather than
        // printing an empty label.
        let attendees = meeting.assignableParticipants.map(\.displayName)
        if !attendees.isEmpty {
            lines.append("- 참석자: \(attendees.joined(separator: ", "))")
        }
        lines.append("")

        lines.append("## 전사")
        lines.append("")

        let utterances = meeting.transcriptSegments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if utterances.isEmpty {
            // Stating the absence beats a document that just stops, which reads as a failed save.
            lines.append("전사 내용이 없습니다.")
        } else {
            for segment in utterances {
                lines.append("[\(Self.timeRange(for: segment))] \(speakerName(for: segment, in: meeting))")
                lines.append("")
                lines.append(segment.text)
                lines.append("")
            }
            lines.removeLast()
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Segment pieces

    /// Follows the meeting's own speaker confirmations: a voice the user identified prints that
    /// person's name, and an unidentified one keeps its anonymous `Speaker N`. Resolution is
    /// scoped to this meeting by `Meeting` itself, so another meeting's `Speaker 1` cannot leak in.
    private func speakerName(for segment: TranscriptSegment, in meeting: Meeting) -> String {
        guard let speakerID = segment.speakerID,
              let participant = meeting.confirmedParticipant(for: speakerID) else {
            return Self.unknownSpeakerLabel
        }
        return participant.displayName
    }

    /// A range when both ends are known, a single time when only the start is, and an explicit
    /// note when there is no timing at all — never a fabricated `00:00`.
    private static func timeRange(for segment: TranscriptSegment) -> String {
        guard let start = TranscriptTimestampFormatter.string(from: segment.startTime) else {
            return "시간 없음"
        }
        guard let end = TranscriptTimestampFormatter.string(from: segment.endTime) else {
            return start
        }
        return "\(start)–\(end)"
    }
}

extension MeetingTranscriptMarkdownRenderer {
    /// Reuses the project export's sanitizer — it is a general filename cleaner despite the name,
    /// and a meeting title is the same kind of untrusted free text. The suffix keeps a transcript
    /// distinguishable from a project status export saved to the same folder.
    static func filename(for meeting: Meeting) -> String {
        ProjectExportFilename.markdownFilename(for: "\(meeting.title) 전사")
    }
}
