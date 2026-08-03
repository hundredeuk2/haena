import Foundation

/// Points back to the exact transcript segment an AI-derived result was extracted from.
/// Timestamps are not duplicated here — they are looked up on the referenced `TranscriptSegment`.
struct EvidenceReference: Codable, Equatable, Sendable {
    let meetingID: UUID
    let transcriptSegmentID: UUID
    let quote: String
}
