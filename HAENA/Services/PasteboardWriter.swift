import AppKit

/// The seam between "copy this text" and the one system pasteboard every app on the machine
/// shares. It exists so tests can assert what would be copied without overwriting whatever the
/// person running them had on their clipboard.
protocol PasteboardWriter {
    /// Returns false when the pasteboard refused the write, so the caller can tell the user
    /// instead of showing a success message for something that did not happen.
    func write(_ string: String) -> Bool
}

struct SystemPasteboardWriter: PasteboardWriter {
    func write(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        // Required before writing: without it the new value is merged into the existing contents
        // rather than replacing them.
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
