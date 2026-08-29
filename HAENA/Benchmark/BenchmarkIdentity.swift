import CryptoKit
import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Derives stable UUIDs for synthetic benchmark objects from corpus string identifiers.
///
/// RFC 9562 version 8 (custom, name-based): SHA-256 over a namespace UUID's 16 bytes followed by
/// the UTF-8 of a scoped name; first 16 bytes taken, version nibble set to 8 and variant to RFC.
/// SHA-256 rather than RFC 4122 v5's SHA-1 — the derivation is new code, so there is no reason to
/// introduce a broken hash for it.
///
/// The point of deriving instead of calling `UUID()` is that a benchmark artifact must be
/// diff-able: re-running the same case against the same stub has to produce byte-identical output,
/// and a random meeting id would make every field that references it churn on every run.
enum BenchmarkIdentity {
    /// Fixed namespace. Changing it renumbers every artifact ever produced, so it never changes.
    ///
    /// Value: `7E9B2C41-5A3D-4F18-9C6E-1B0A8D5F3E27`. Generated once, at random, for this harness.
    /// It is not derived from anything and carries no meaning; its only job is to keep these ids
    /// from colliding with ids derived by any other name-based UUID scheme.
    static let namespace = UUID(uuidString: "7E9B2C41-5A3D-4F18-9C6E-1B0A8D5F3E27")!

    // MARK: - Derivations

    static func meetingID(benchmark: String, caseID: String) -> UUID {
        derive(scopedName(["meeting", benchmark, caseID]))
    }

    static func projectID(benchmark: String, caseID: String) -> UUID {
        derive(scopedName(["project", benchmark, caseID]))
    }

    static func participantID(benchmark: String, caseID: String, speaker: String) -> UUID {
        derive(scopedName(["participant", benchmark, caseID, speaker]))
    }

    static func segmentID(benchmark: String, caseID: String, utteranceID: String) -> UUID {
        derive(scopedName(["utterance", benchmark, caseID, utteranceID]))
    }

    /// Deterministic ids for mapper-produced domain objects, so re-running yields byte-identical
    /// artifacts. `ordinal` is the 0-based index within the run.
    static func proposalID(benchmark: String, caseID: String, ordinal: Int) -> UUID {
        derive(scopedName(["proposal", benchmark, caseID, String(ordinal)]))
    }

    // MARK: - Name scoping

    /// ASCII unit separator (U+001F). Joining components with it is what makes case boundaries
    /// impossible to cross: the corpus's identifiers are benchmark slugs, `MEV0-0NN` case ids, and
    /// dotted utterance ids such as `DGBEC21000067.1.1.1`, none of which can contain a control
    /// character. A separator that *could* appear in a component — `-`, `.`, `:` — would let
    /// `("MEV0-004", "1.1")` and `("MEV0", "004.1.1")` hash to the same name.
    ///
    /// The leading kind component ("meeting", "participant", …) scopes the derivation the same way,
    /// so a participant and a segment can never share an id even given identical trailing strings.
    private static let unitSeparator = "\u{1F}"

    private static func scopedName(_ components: [String]) -> String {
        components.joined(separator: unitSeparator)
    }

    // MARK: - RFC 9562 version 8

    private static func derive(_ name: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: namespaceBytes)
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))

        // Version 8 = "custom" in RFC 9562: the layout of the remaining bits is defined by this
        // application, which is exactly the case here.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        // Variant 10xx = RFC 4122/9562, so the value is a well-formed UUID everywhere it is parsed.
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The namespace's 16 bytes in RFC big-endian order, which is exactly how `uuid_t` stores them.
    private static var namespaceBytes: Data {
        withUnsafeBytes(of: namespace.uuid) { Data($0) }
    }
}
