import Foundation

/// A slice of a meeting's transcript, attributable to a speaker.
///
/// `startTime`/`endTime` are seconds relative to the meeting's start, not wall-clock `Date`s.
/// They are optional because pasted-text input has no timing information at all.
struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    /// References `Participant.id` of the speaker within the same meeting.
    /// Nil when the speaker is unknown or not applicable, e.g. pasted-text input.
    let speakerID: UUID?
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
}
