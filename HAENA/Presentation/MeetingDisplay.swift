import Foundation

/// Korean display copy for `MeetingSourceType`. Kept out of the domain enum itself so the
/// model stays free of presentation concerns.
enum MeetingSourceTypeDisplay {
    static func label(for sourceType: MeetingSourceType) -> String {
        switch sourceType {
        case .microphone:
            return "마이크 녹음"
        case .audioFile:
            return "음성 파일"
        case .videoFile:
            return "영상 파일"
        case .pastedText:
            return "텍스트 입력"
        }
    }
}

/// Display text for a project's meeting count.
enum MeetingCountDisplay {
    static func label(count: Int) -> String {
        "회의 \(count)개"
    }
}

/// Resolves a transcript segment's speaker to display text, or nil when there is nothing to
/// show — no speaker ID, or no matching participant. Callers must omit the speaker header
/// entirely in that case rather than showing an empty one.
enum TranscriptSpeakerDisplay {
    static func label(for segment: TranscriptSegment, in meeting: Meeting) -> String? {
        guard let speakerID = segment.speakerID else {
            return nil
        }
        guard let participant = meeting.participants.first(where: { $0.id == speakerID }) else {
            return nil
        }
        // Once the user has confirmed whose voice this is, that name wins over the provider's own
        // label. Until then the behaviour is unchanged.
        if let confirmed = meeting.confirmedParticipant(for: speakerID), confirmed.id != speakerID {
            return confirmed.displayName
        }
        return participant.speakerLabel ?? participant.displayName
    }
}
