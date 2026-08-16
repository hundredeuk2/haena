import XCTest
@testable import HAENA

final class BenchmarkIdentityTests: XCTestCase {
    private let benchmark = "meeting-execution-v0"
    private let caseID = "MEV0-004"
    private let utteranceID = "DGBEC21000067.1.1.1"

    // MARK: - Determinism

    func testTheSameCaseAndUtteranceAlwaysDeriveTheSameID() {
        let first = BenchmarkIdentity.segmentID(
            benchmark: benchmark,
            caseID: caseID,
            utteranceID: utteranceID
        )
        let second = BenchmarkIdentity.segmentID(
            benchmark: benchmark,
            caseID: caseID,
            utteranceID: utteranceID
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            UUID(uuidString: "5BDFF6DF-E6CE-8B77-B435-0D7C2B8CFAC1"),
            "changing the derivation renumbers every artifact ever written"
        )
    }

    /// Pins the namespace and one derivation of every kind. These constants are the contract with
    /// artifacts already on disk: if this test has to be updated, the format version must change too.
    func testEveryDerivationKindIsFrozenToAKnownValue() {
        XCTAssertEqual(
            BenchmarkIdentity.namespace,
            UUID(uuidString: "7E9B2C41-5A3D-4F18-9C6E-1B0A8D5F3E27")
        )
        XCTAssertEqual(
            BenchmarkIdentity.meetingID(benchmark: benchmark, caseID: caseID),
            UUID(uuidString: "72C546CD-89CE-8DF1-93B7-08322A8D839C")
        )
        XCTAssertEqual(
            BenchmarkIdentity.projectID(benchmark: benchmark, caseID: caseID),
            UUID(uuidString: "E068F456-9618-8666-A42A-2E54829BF5D0")
        )
        XCTAssertEqual(
            BenchmarkIdentity.participantID(benchmark: benchmark, caseID: caseID, speaker: "A"),
            UUID(uuidString: "196E16F5-3E9F-8B49-830B-F33249CC77C7")
        )
        XCTAssertEqual(
            BenchmarkIdentity.proposalID(benchmark: benchmark, caseID: caseID, ordinal: 0),
            UUID(uuidString: "9FE9810B-1496-8ADE-9EA9-FEEDF19C9EB5")
        )
    }

    // MARK: - Collision resistance

    func testTheSameUtteranceIDInDifferentCasesDerivesDifferentIDs() {
        let inFourth = BenchmarkIdentity.segmentID(benchmark: benchmark, caseID: "MEV0-004", utteranceID: "U1")
        let inFifth = BenchmarkIdentity.segmentID(benchmark: benchmark, caseID: "MEV0-005", utteranceID: "U1")

        XCTAssertNotEqual(inFourth, inFifth)
        XCTAssertEqual(inFourth, UUID(uuidString: "211777DD-B42B-84D2-A92D-8B5504D64C74"))
        XCTAssertEqual(inFifth, UUID(uuidString: "6275CD4F-A521-8D5E-9FE8-B3B64C31C5AD"))
    }

    func testTheSameUtteranceIDInDifferentBenchmarksDerivesDifferentIDs() {
        XCTAssertNotEqual(
            BenchmarkIdentity.segmentID(benchmark: "meeting-execution-v0", caseID: caseID, utteranceID: "U1"),
            BenchmarkIdentity.segmentID(benchmark: "meeting-execution-v1", caseID: caseID, utteranceID: "U1")
        )
    }

    /// The leading kind component is what keeps a participant from colliding with a segment, so a
    /// speaker literally named like an utterance still gets its own id.
    func testDifferentScopesNeverShareAnID() {
        let ids: Set<UUID> = [
            BenchmarkIdentity.meetingID(benchmark: benchmark, caseID: caseID),
            BenchmarkIdentity.projectID(benchmark: benchmark, caseID: caseID),
            BenchmarkIdentity.participantID(benchmark: benchmark, caseID: caseID, speaker: "X"),
            BenchmarkIdentity.segmentID(benchmark: benchmark, caseID: caseID, utteranceID: "X"),
            BenchmarkIdentity.proposalID(benchmark: benchmark, caseID: caseID, ordinal: 0)
        ]

        XCTAssertEqual(ids.count, 5)
    }

    func testEachSpeakerLabelAndEachOrdinalGetsItsOwnID() {
        let participants = ["A", "B", "C", "D"].map {
            BenchmarkIdentity.participantID(benchmark: benchmark, caseID: caseID, speaker: $0)
        }
        let proposals = (0..<8).map {
            BenchmarkIdentity.proposalID(benchmark: benchmark, caseID: caseID, ordinal: $0)
        }

        XCTAssertEqual(Set(participants).count, 4)
        XCTAssertEqual(Set(proposals).count, 8)
    }

    // MARK: - Well-formedness

    func testDerivedIDsAreRFC9562Version8WithTheRFCVariant() {
        let derived = [
            BenchmarkIdentity.meetingID(benchmark: benchmark, caseID: caseID),
            BenchmarkIdentity.projectID(benchmark: benchmark, caseID: caseID),
            BenchmarkIdentity.participantID(benchmark: benchmark, caseID: caseID, speaker: "A"),
            BenchmarkIdentity.segmentID(benchmark: benchmark, caseID: caseID, utteranceID: utteranceID),
            BenchmarkIdentity.proposalID(benchmark: benchmark, caseID: caseID, ordinal: 3)
        ]

        for id in derived {
            let bytes = id.uuid
            XCTAssertEqual(bytes.6 >> 4, 0x8, "version nibble must be 8 (custom)")
            XCTAssertEqual(bytes.8 & 0xC0, 0x80, "variant must be RFC 4122/9562")
        }
    }

    /// A derived id must survive the string round trip the artifact format puts it through.
    func testDerivedIDsRoundTripThroughTheirStringForm() {
        let id = BenchmarkIdentity.segmentID(benchmark: benchmark, caseID: caseID, utteranceID: utteranceID)

        XCTAssertEqual(UUID(uuidString: id.uuidString), id)
    }
}
