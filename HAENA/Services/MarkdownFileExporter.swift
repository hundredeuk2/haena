import AppKit

/// What happened when the user was asked where to save. Cancelling is a distinct outcome from
/// failing, because dismissing a save panel is a decision — reporting it as an error would tell
/// the user something went wrong when nothing did.
enum MarkdownExportOutcome: Equatable {
    case saved
    case cancelled
    case failed
}

/// The seam between "save this Markdown" and the filesystem, so tests can exercise the export path
/// without a modal panel appearing or a file being written.
///
/// Main-actor bound because presenting a panel is: the only caller is a button action, which is
/// already there.
@MainActor
protocol MarkdownFileExporter {
    func export(_ markdown: String, suggestedFilename: String) -> MarkdownExportOutcome
}

/// The standard macOS save panel: the user picks the location, and overwriting an existing file
/// goes through the system's own confirmation rather than anything this app invents.
struct SavePanelMarkdownExporter: MarkdownFileExporter {
    func export(_ markdown: String, suggestedFilename: String) -> MarkdownExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.markdownText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            try MarkdownExportData.utf8Data(markdown).write(to: url, options: .atomic)
            return .saved
        } catch {
            // The error itself is deliberately not surfaced or logged: it can carry the full path
            // the user chose, and the caller only needs to know the save did not happen.
            return .failed
        }
    }
}
