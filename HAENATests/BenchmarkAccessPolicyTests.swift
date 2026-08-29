import XCTest
@testable import HAENA

/// The permission layer of the harness, tested on its own so that the guarantees hold as
/// properties of the policy value rather than as habits of whoever calls it.
///
/// Two guarantees carry the whole design and both are asserted as *failures*, not as warnings:
/// a sealed-holdout case is unreadable unless this run was explicitly unlocked, and an external
/// provider is unusable unless three independent permissions are all present.
final class BenchmarkAccessPolicyTests: XCTestCase {
    // MARK: - Entry construction

    /// Source-index entries are built by decoding, not by a memberwise initializer, so this suite
    /// depends only on the wire contract (`source-index.jsonl`'s snake_case keys) and not on the
    /// shape of another agent's initializer.
    private func entry(
        _ caseID: String,
        split: String,
        benchmark: String = "meeting-execution-v0"
    ) throws -> BenchmarkSourceIndexEntry {
        let json = """
        {"case_id": "\(caseID)", "split": "\(split)", "benchmark": "\(benchmark)", \
        "schema_version": "haena-benchmark-v0.1", "review_status": "human_review_pending", \
        "case_path": "cases/\(caseID).json"}
        """
        return try JSONDecoder().decode(BenchmarkSourceIndexEntry.self, from: Data(json.utf8))
    }

    private func development(_ caseID: String) throws -> BenchmarkSourceIndexEntry {
        try entry(caseID, split: "development")
    }

    private func sealed(_ caseID: String) throws -> BenchmarkSourceIndexEntry {
        try entry(caseID, split: "sealed_holdout")
    }

    private func assertThrows<T>(
        _ expected: BenchmarkAccessError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? BenchmarkAccessError, expected, file: file, line: line)
        }
    }

    // MARK: - Defaults

    /// The default is the safety property: a policy nobody configured can read development cases
    /// and nothing else, and can reach no network.
    func testTheDefaultPolicyGrantsNothingBeyondTheDevelopmentSplit() throws {
        let policy = BenchmarkAccessPolicy()

        XCTAssertFalse(policy.unlockedSealedHoldout)
        XCTAssertFalse(policy.allowNetwork)
        XCTAssertFalse(policy.datasetTransferConfirmed)
        XCTAssertTrue(policy.allowedProviders.isEmpty)
        XCTAssertEqual(policy, .offlineDefault, "offlineDefault must be the unconfigured value itself")

        XCTAssertNoThrow(try policy.authorizeSplit(.development))
        XCTAssertNoThrow(try policy.authorizeProvider(.offlineStub))
    }

    // MARK: - Sealed holdout: split

    func testRequestingTheSealedSplitUnderTheDefaultPolicyFails() {
        assertThrows(.sealedHoldoutLocked(caseIDs: []), try BenchmarkAccessPolicy().authorizeSplit(.sealedHoldout))
    }

    /// The refusal for a whole-split request names no case. Listing the sealed ids in the error
    /// would hand over part of the holdout's composition to anyone who typed the wrong flag.
    func testTheWholeSplitRefusalNamesNoCase() {
        do {
            try BenchmarkAccessPolicy().authorizeSplit(.sealedHoldout)
            XCTFail("a locked sealed split must fail")
        } catch let error as BenchmarkAccessError {
            guard case .sealedHoldoutLocked(let caseIDs) = error else {
                return XCTFail("expected a sealed-holdout refusal, got \(error)")
            }
            XCTAssertTrue(caseIDs.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnUnlockedPolicyAllowsTheSealedSplit() {
        var policy = BenchmarkAccessPolicy()
        policy.unlockedSealedHoldout = true

        XCTAssertNoThrow(try policy.authorizeSplit(.sealedHoldout))
        XCTAssertNoThrow(try policy.authorizeSplit(.development))
    }

    // MARK: - Sealed holdout: explicit case ids

    func testASingleSealedCaseAmongDevelopmentCasesFailsTheWholeRequest() throws {
        let entries = [
            try development("SYN-D1"),
            try sealed("SYN-H1"),
            try development("SYN-D2")
        ]

        assertThrows(
            .sealedHoldoutLocked(caseIDs: ["SYN-H1"]),
            try BenchmarkAccessPolicy().authorizeCases(entries)
        )
    }

    /// The refusal names every offending case, in the order requested and without repeats, so an
    /// operator can fix the invocation in one pass instead of one failure at a time.
    func testTheRefusalListsEveryRequestedSealedCaseOnceInRequestOrder() throws {
        let entries = [
            try sealed("SYN-H2"),
            try development("SYN-D1"),
            try sealed("SYN-H1"),
            try sealed("SYN-H2")
        ]

        assertThrows(
            .sealedHoldoutLocked(caseIDs: ["SYN-H2", "SYN-H1"]),
            try BenchmarkAccessPolicy().authorizeCases(entries)
        )
    }

    func testDevelopmentOnlyRequestsPassAndAnEmptyRequestIsNotAnError() throws {
        let policy = BenchmarkAccessPolicy()

        XCTAssertNoThrow(try policy.authorizeCases([try development("SYN-D1"), try development("SYN-D2")]))
        XCTAssertNoThrow(try policy.authorizeCases([]))
    }

    func testAnUnlockedPolicyAllowsSealedCaseIDs() throws {
        var policy = BenchmarkAccessPolicy()
        policy.unlockedSealedHoldout = true

        XCTAssertNoThrow(try policy.authorizeCases([try sealed("SYN-H1"), try development("SYN-D1")]))
    }

    // MARK: - Providers

    func testTheOfflineStubNeedsNoPermissionAtAll() {
        XCTAssertNoThrow(try BenchmarkAccessPolicy().authorizeProvider(.offlineStub))
        XCTAssertEqual(BenchmarkProviderSelection.offlineStub.identifier, "stub")
        XCTAssertEqual(BenchmarkProviderSelection.offlineStub.runMode, "offline_stub")
    }

    func testAnExternalProviderCarriesItsIdentifierAndTheProviderRunMode() {
        let openAI = BenchmarkProviderSelection.external(identifier: "openai")
        XCTAssertEqual(openAI.identifier, "openai")
        XCTAssertEqual(openAI.runMode, "provider")
    }

    /// The truth table. An external provider needs an allow-list entry, network permission, and
    /// dataset-transfer confirmation; every combination that is missing one of the three fails, and
    /// each failure says which one is missing.
    func testAnExternalProviderNeedsAllThreePermissionsAndEachTwoOfThreeCombinationFails() {
        let openAI = BenchmarkProviderSelection.external(identifier: "openai")

        func policy(allowList: Bool, network: Bool, transfer: Bool) -> BenchmarkAccessPolicy {
            var policy = BenchmarkAccessPolicy()
            policy.allowedProviders = allowList ? ["openai"] : []
            policy.allowNetwork = network
            policy.datasetTransferConfirmed = transfer
            return policy
        }

        // None.
        assertThrows(
            .providerNotAllowed(provider: "openai"),
            try policy(allowList: false, network: false, transfer: false).authorizeProvider(openAI)
        )

        // Exactly one.
        assertThrows(
            .networkNotAllowed(provider: "openai"),
            try policy(allowList: true, network: false, transfer: false).authorizeProvider(openAI)
        )
        assertThrows(
            .providerNotAllowed(provider: "openai"),
            try policy(allowList: false, network: true, transfer: false).authorizeProvider(openAI)
        )
        assertThrows(
            .providerNotAllowed(provider: "openai"),
            try policy(allowList: false, network: false, transfer: true).authorizeProvider(openAI)
        )

        // Exactly two — the combinations most likely to be reached by a half-written command line.
        assertThrows(
            .datasetTransferNotConfirmed(provider: "openai"),
            try policy(allowList: true, network: true, transfer: false).authorizeProvider(openAI)
        )
        assertThrows(
            .networkNotAllowed(provider: "openai"),
            try policy(allowList: true, network: false, transfer: true).authorizeProvider(openAI)
        )
        assertThrows(
            .providerNotAllowed(provider: "openai"),
            try policy(allowList: false, network: true, transfer: true).authorizeProvider(openAI)
        )

        // All three.
        XCTAssertNoThrow(try policy(allowList: true, network: true, transfer: true).authorizeProvider(openAI))
    }

    /// Consent to transfer is not consent to a recipient: fully permitting one provider grants
    /// nothing to another.
    func testPermissionGrantedToOneProviderDoesNotTransferToAnother() {
        var policy = BenchmarkAccessPolicy()
        policy.allowedProviders = ["openai"]
        policy.allowNetwork = true
        policy.datasetTransferConfirmed = true

        XCTAssertNoThrow(try policy.authorizeProvider(.external(identifier: "openai")))
        assertThrows(
            .providerNotAllowed(provider: "some-other-vendor"),
            try policy.authorizeProvider(.external(identifier: "some-other-vendor"))
        )
    }

    /// Network permission is orthogonal to the holdout lock: neither grants the other.
    func testNetworkPermissionDoesNotUnlockTheHoldoutAndUnlockingDoesNotGrantNetwork() throws {
        var networked = BenchmarkAccessPolicy()
        networked.allowNetwork = true
        networked.datasetTransferConfirmed = true
        networked.allowedProviders = ["openai"]
        assertThrows(.sealedHoldoutLocked(caseIDs: []), try networked.authorizeSplit(.sealedHoldout))

        var unlocked = BenchmarkAccessPolicy()
        unlocked.unlockedSealedHoldout = true
        assertThrows(
            .providerNotAllowed(provider: "openai"),
            try unlocked.authorizeProvider(.external(identifier: "openai"))
        )
    }
}
