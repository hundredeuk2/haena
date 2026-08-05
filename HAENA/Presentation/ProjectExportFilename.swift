import Foundation

/// Turns a project name into a filename the save panel can offer.
///
/// A project name is free text a user typed — it can contain path separators, colons, control
/// characters, or nothing at all — so it is never handed to the filesystem as-is.
enum ProjectExportFilename {
    static let markdownExtension = "md"

    /// Characters that either break a path or are rejected/mangled by common filesystems and the
    /// tools these exports get dragged into.
    private static let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|")

    /// Long enough for any reasonable project name, short enough to stay clear of the 255-byte
    /// filename limit once multi-byte Korean characters are counted.
    private static let maximumNameLength = 100

    /// Used when sanitizing leaves nothing behind — a name of only slashes, or only spaces.
    /// Deliberately ASCII so the fallback itself can never be the thing that fails to save.
    private static let fallbackName = "project"

    static func markdownFilename(for projectName: String) -> String {
        "\(sanitized(projectName)).\(markdownExtension)"
    }

    static func sanitized(_ projectName: String) -> String {
        let withoutDisallowed = projectName
            .components(separatedBy: disallowed.union(.controlCharacters))
            .joined(separator: " ")

        let collapsed = withoutDisallowed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // A leading dot would hide the file in Finder, which reads as the save having failed.
        let visible = collapsed.hasPrefix(".") ? String(collapsed.drop(while: { $0 == "." })) : collapsed

        let trimmed = String(visible.prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespaces)

        return trimmed.isEmpty ? fallbackName : trimmed
    }
}
