import XCTest
@testable import HAENA

/// The parser is the harness's only user-facing surface, and the flags it reads decide whether a
/// run can reach the network or open a sealed-holdout case. These tests pin down both the parsing
/// and the *defaults*, because the defaults are the safety property: forgetting a flag must never
/// widen what a run is allowed to do.
final class BenchmarkCommandLineTests: XCTestCase {
    private let required = ["--dataset-root", "corpus", "--output-dir", "out"]

    private func assertParseFails(
        _ arguments: [String],
        with expected: BenchmarkCommandLine.ParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try BenchmarkCommandLine.parse(arguments)
            XCTFail("expected parsing to fail with \(expected)", file: file, line: line)
        } catch let error as BenchmarkCommandLine.ParseError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Required flags

    func testParsesTheTwoRequiredFlags() throws {
        let options = try BenchmarkCommandLine.parse(required)

        XCTAssertEqual(options.datasetRoot, "corpus")
        XCTAssertEqual(options.outputDirectory, "out")
    }

    func testMissingDatasetRootIsRejected() {
        assertParseFails(["--output-dir", "out"], with: .missingRequired(flag: "--dataset-root"))
    }

    func testMissingOutputDirectoryIsRejected() {
        // There is deliberately no default output directory, so this can never be defaulted away.
        assertParseFails(["--dataset-root", "corpus"], with: .missingRequired(flag: "--output-dir"))
    }

    func testFlagWithoutAValueIsRejected() {
        assertParseFails(["--dataset-root"], with: .missingValue(flag: "--dataset-root"))
    }

    func testFlagFollowedByAnotherFlagIsRejectedRatherThanConsumingIt() {
        // `--dataset-root --output-dir out` must not silently use "--output-dir" as a path.
        assertParseFails(
            ["--dataset-root", "--output-dir", "out"],
            with: .missingValue(flag: "--dataset-root")
        )
    }

    func testUnknownFlagIsRejected() {
        assertParseFails(required + ["--score"], with: .unknownFlag("--score"))
    }

    func testBarePositionalArgumentIsRejected() {
        assertParseFails(required + ["MEV0-004"], with: .unknownFlag("MEV0-004"))
    }

    // MARK: - Defaults

    func testDefaultsAreTheSafestValues() throws {
        let options = try BenchmarkCommandLine.parse(required)

        XCTAssertEqual(options.benchmark, "meeting-execution-v0")
        XCTAssertEqual(options.split, .development)
        XCTAssertTrue(options.caseIDs.isEmpty, "an empty case list means the whole split")
        XCTAssertEqual(options.provider, .offlineStub)
        XCTAssertNil(options.gitRevision)

        XCTAssertEqual(options.policy, .offlineDefault)
        XCTAssertFalse(options.policy.allowNetwork)
        XCTAssertFalse(options.policy.datasetTransferConfirmed)
        XCTAssertFalse(options.policy.unlockedSealedHoldout)
        XCTAssertTrue(options.policy.allowedProviders.isEmpty)
    }

    func testBenchmarkNameCanBeOverridden() throws {
        let options = try BenchmarkCommandLine.parse(required + ["--benchmark", "other-v1"])

        XCTAssertEqual(options.benchmark, "other-v1")
    }

    func testGitRevisionIsCarriedThroughUnchanged() throws {
        let options = try BenchmarkCommandLine.parse(required + ["--git-revision", "abc1234"])

        XCTAssertEqual(options.gitRevision, "abc1234")
    }

    // MARK: - Case selection

    func testCaseFlagRepeatsAndKeepsItsOrder() throws {
        let options = try BenchmarkCommandLine.parse(
            required + ["--case", "MEV0-004", "--case", "MEV0-011", "--case", "MEV0-005"]
        )

        XCTAssertEqual(options.caseIDs, ["MEV0-004", "MEV0-011", "MEV0-005"])
    }

    func testCaseFlagWithoutAValueIsRejected() {
        assertParseFails(required + ["--case"], with: .missingValue(flag: "--case"))
    }

    // MARK: - Split

    func testParsesBothSplitNames() throws {
        XCTAssertEqual(try BenchmarkCommandLine.parse(required + ["--split", "development"]).split, .development)
        XCTAssertEqual(
            try BenchmarkCommandLine.parse(required + ["--split", "sealed_holdout"]).split,
            .sealedHoldout
        )
    }

    func testUnknownSplitIsRejected() {
        assertParseFails(required + ["--split", "test"], with: .unknownSplit("test"))
    }

    func testSealedHoldoutWithoutTheUnlockFlagIsRefusedByThePolicy() throws {
        let options = try BenchmarkCommandLine.parse(required + ["--split", "sealed_holdout"])

        XCTAssertFalse(options.policy.unlockedSealedHoldout)
        XCTAssertThrowsError(try options.policy.authorizeSplit(.sealedHoldout)) { error in
            guard let accessError = error as? BenchmarkAccessError else {
                return XCTFail("expected a BenchmarkAccessError, got \(error)")
            }
            if case .sealedHoldoutLocked = accessError {
                return
            }
            XCTFail("expected sealedHoldoutLocked, got \(accessError)")
        }
    }

    func testUnlockFlagOpensTheSealedHoldoutSplit() throws {
        let options = try BenchmarkCommandLine.parse(
            required + ["--split", "sealed_holdout", "--unlock-sealed-holdout"]
        )

        XCTAssertTrue(options.policy.unlockedSealedHoldout)
        XCTAssertNoThrow(try options.policy.authorizeSplit(.sealedHoldout))
    }

    // MARK: - Provider

    func testDefaultProviderIsTheOfflineStubAndNeedsNoPermission() throws {
        let options = try BenchmarkCommandLine.parse(required)

        XCTAssertEqual(options.provider.runMode, "offline_stub")
        XCTAssertNoThrow(try options.policy.authorizeProvider(options.provider))
    }

    func testParsesTheExternalProviderAndAllowListsExactlyIt() throws {
        let options = try BenchmarkCommandLine.parse(required + ["--provider", "openai"])

        XCTAssertEqual(options.provider, .external(identifier: "openai"))
        XCTAssertEqual(options.provider.identifier, "openai")
        XCTAssertEqual(options.provider.runMode, "provider")
        XCTAssertEqual(options.policy.allowedProviders, ["openai"])
    }

    func testExternalProviderWithoutTheConsentFlagsIsRefusedByThePolicy() throws {
        // Naming the provider is not consent to reach a network or to ship transcripts to it.
        let networkOnly = try BenchmarkCommandLine.parse(required + ["--provider", "openai"])
        XCTAssertThrowsError(try networkOnly.policy.authorizeProvider(networkOnly.provider))

        let withNetwork = try BenchmarkCommandLine.parse(
            required + ["--provider", "openai", "--allow-network"]
        )
        XCTAssertThrowsError(try withNetwork.policy.authorizeProvider(withNetwork.provider))

        let withTransfer = try BenchmarkCommandLine.parse(
            required + ["--provider", "openai", "--i-accept-dataset-transfer"]
        )
        XCTAssertThrowsError(try withTransfer.policy.authorizeProvider(withTransfer.provider))
    }

    func testExternalProviderWithEveryConsentFlagIsAuthorized() throws {
        let options = try BenchmarkCommandLine.parse(
            required + ["--provider", "openai", "--allow-network", "--i-accept-dataset-transfer"]
        )

        XCTAssertTrue(options.policy.allowNetwork)
        XCTAssertTrue(options.policy.datasetTransferConfirmed)
        XCTAssertNoThrow(try options.policy.authorizeProvider(options.provider))
    }

    func testUnknownProviderIsRejected() {
        assertParseFails(required + ["--provider", "anthropic"], with: .unknownProvider("anthropic"))
    }

    // MARK: - Help and usage

    func testHelpIsRecognisedWithoutTheRequiredFlags() {
        XCTAssertTrue(BenchmarkCommandLine.wantsHelp(["--help"]))
        XCTAssertTrue(BenchmarkCommandLine.wantsHelp(["--dataset-root", "corpus", "--help"]))
        XCTAssertFalse(BenchmarkCommandLine.wantsHelp(required))
    }

    func testHelpDoesNotCountAsAnUnknownFlagWhenMixedWithRealOnes() throws {
        let options = try BenchmarkCommandLine.parse(required + ["--help"])

        XCTAssertEqual(options.datasetRoot, "corpus")
    }

    func testUsageDocumentsEveryFlagAndPromisesNoScore() {
        let usage = BenchmarkCommandLine.usage

        for flag in [
            "--dataset-root",
            "--output-dir",
            "--benchmark",
            "--split",
            "--case",
            "--provider",
            "--allow-network",
            "--i-accept-dataset-transfer",
            "--unlock-sealed-holdout",
            "--git-revision",
            "--help"
        ] {
            XCTAssertTrue(usage.contains(flag), "usage must document \(flag)")
        }

        XCTAssertTrue(usage.contains("There is no default"), "the absence of an output-dir default is the point")
        XCTAssertTrue(usage.contains("computes no score"))
        XCTAssertFalse(usage.contains("/Users/"), "usage must not embed anyone's home directory")
    }
}
