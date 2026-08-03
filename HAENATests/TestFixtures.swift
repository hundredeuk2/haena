import Foundation
@testable import HAENA

/// Fixed IDs and dates shared across model/repository tests so results are reproducible
/// instead of depending on `UUID()`/`Date()` at test-run time.
enum TestFixtures {
    static let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let participantID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    /// A later timestamp than `fixedDate`, for asserting that a second operation (e.g. saving
    /// a meeting) advances `updatedAt` past the original creation time.
    static let laterDate = Date(timeIntervalSince1970: 1_700_000_100)
}
