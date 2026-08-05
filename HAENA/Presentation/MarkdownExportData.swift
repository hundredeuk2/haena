import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// `.plainText` would make the save panel offer a `.txt` extension. Deriving the type from the
    /// extension keeps the suggested filename a Markdown one; falling back to plain text means a
    /// machine that cannot resolve it still saves readable text rather than failing.
    static var markdownText: UTType {
        UTType(filenameExtension: ProjectExportFilename.markdownExtension, conformingTo: .plainText) ?? .plainText
    }
}

/// The bytes an export actually writes.
enum MarkdownExportData {
    /// UTF-8 explicitly: the document is mostly Korean, and the default encoding of whatever opens
    /// it next cannot be assumed.
    static func utf8Data(_ text: String) throws -> Data {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }
}
