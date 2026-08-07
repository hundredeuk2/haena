import Foundation

/// Builds a `multipart/form-data` body.
///
/// Hand-rolled rather than pulled in as a dependency because the transcription endpoint needs
/// exactly one file part and a handful of scalar fields, and because the boundary must be
/// injectable — a random boundary would make the adapter's request body untestable.
struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    /// Closes the body. Call once, last — appending after this produces a malformed request.
    func encoded() -> Data {
        var closed = body
        closed.append("--\(boundary)--\r\n")
        return closed
    }

    /// Maps the container extensions HAE.NA accepts onto the MIME types OpenAI expects.
    /// Falls back to a generic binary type rather than guessing, since the endpoint reads the
    /// filename extension too.
    static func contentType(forFileExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp3", "mpga":
            return "audio/mpeg"
        case "mpeg":
            return "video/mpeg"
        case "mp4", "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
