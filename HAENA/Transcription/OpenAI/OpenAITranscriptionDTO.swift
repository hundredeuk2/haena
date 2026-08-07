import Foundation

/// Wire shape of a `diarized_json` transcription response.
///
/// Every field is optional because this is untrusted input from over the network: a response that
/// omits `speaker`, or drops timings, must decode to a value the adapter can inspect and reject
/// deliberately — not throw a decoding error that gets reported as "malformed" when the real
/// answer is "this provider gave us no speakers".
///
/// This type never leaves the adapter. Nothing in `Transcription.swift`, the services, or the
/// views knows it exists.
struct OpenAITranscriptionReply: Decodable {
    struct Segment: Decodable {
        let text: String?
        let start: Double?
        let end: Double?
        let speaker: String?
    }

    struct ErrorBody: Decodable {
        let message: String?
        let type: String?
    }

    let text: String?
    let segments: [Segment]?
    let error: ErrorBody?
}
