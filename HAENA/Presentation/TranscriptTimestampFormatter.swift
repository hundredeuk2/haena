import Foundation

/// Formats a transcript segment's offset (seconds from meeting start) as `mm:ss`, or
/// `hh:mm:ss` once past an hour. Returns nil for a nil timestamp — callers must not
/// fabricate a placeholder like `00:00` for input with no timing information.
enum TranscriptTimestampFormatter {
    static func string(from seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else {
            return nil
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
