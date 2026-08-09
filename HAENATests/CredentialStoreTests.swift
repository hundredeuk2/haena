import XCTest
@testable import HAENA

/// Covers credential storage and the one place that decides which key the app uses.
///
/// **No test here reaches the network or the real login Keychain.** The Keychain store is exercised
/// against a throwaway service name so nothing can collide with — or overwrite — the key a real
/// user has saved, and the verifier is only ever the injected double.
final class CredentialStoreTests: XCTestCase {
    private static let sampleKey = "sk-test-0123456789abcdef"
    private static let otherKey = "sk-test-fedcba9876543210"

    // MARK: - In-memory store

    func testSavingReadingReplacingAndDeleting() throws {
        let store = InMemoryAPICredentialStore()
        XCTAssertNil(try store.credential())

        try store.save(Self.sampleKey)
        XCTAssertEqual(try store.credential(), Self.sampleKey)

        try store.save(Self.otherKey)
        XCTAssertEqual(try store.credential(), Self.otherKey, "Saving again replaces rather than adds.")

        try store.delete()
        XCTAssertNil(try store.credential())
    }

    func testDeletingWhenNothingIsStoredIsHarmless() throws {
        let store = InMemoryAPICredentialStore()
        try store.delete()
        try store.delete()
        XCTAssertNil(try store.credential())
    }

    func testBlankCredentialsAreRefused() {
        let store = InMemoryAPICredentialStore()
        for blank in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(try store.save(blank)) { error in
                XCTAssertEqual(error as? CredentialStoreError, .blankCredential)
            }
        }
        XCTAssertNil(try? store.credential())
    }

    func testSurroundingWhitespaceIsTrimmedOnSave() throws {
        let store = InMemoryAPICredentialStore()
        try store.save("  \(Self.sampleKey)\n")
        XCTAssertEqual(try store.credential(), Self.sampleKey, "A pasted key often carries a newline.")
    }

    // MARK: - Keychain error mapping

    /// "The user said no" and "the Keychain is broken" need different messages, so they must not
    /// collapse into one error.
    func testKeychainStatusesMapToDistinctErrors() {
        XCTAssertEqual(KeychainAPICredentialStore.mapped(errSecUserCanceled), .accessDenied)
        XCTAssertEqual(KeychainAPICredentialStore.mapped(errSecInteractionNotAllowed), .accessDenied)
        XCTAssertEqual(KeychainAPICredentialStore.mapped(errSecAuthFailed), .accessDenied)
        XCTAssertEqual(KeychainAPICredentialStore.mapped(errSecIO), .unavailable(status: errSecIO))
    }

    /// The item's name is fixed in one place, so a second credential cannot quietly land in this
    /// one's slot.
    func testTheKeychainItemIsNamedInExactlyOnePlace() {
        XCTAssertEqual(CredentialItem.service, "com.haena.HAENA")
        XCTAssertEqual(CredentialItem.Account.openAI, "openai-api-key")
    }

    /// The real Keychain, against a throwaway item so the user's own key is untouchable from here.
    /// Also covers the duplicate-item path: saving twice must update, never accumulate.
    func testRealKeychainStoreRoundTripsAndReplacesWithoutDuplicating() throws {
        let account = "haena-tests-\(UUID().uuidString)"
        let store = KeychainAPICredentialStore(service: CredentialItem.service, account: account)
        addTeardownBlock { try? store.delete() }

        do {
            try store.save(Self.sampleKey)
        } catch {
            throw XCTSkip("This machine's Keychain is not writable in this context: \(error)")
        }

        XCTAssertEqual(try store.credential(), Self.sampleKey)

        try store.save(Self.otherKey)
        XCTAssertEqual(try store.credential(), Self.otherKey, "A second save updates the one item.")

        try store.delete()
        XCTAssertNil(try store.credential())
        try store.delete()
    }

    // MARK: - Resolver priority

    func testEnvironmentWinsOverTheKeychain() {
        let store = InMemoryAPICredentialStore(credential: Self.otherKey)
        let resolver = OpenAICredentialResolver(store: store, environment: { ["OPENAI_API_KEY": Self.sampleKey] })

        XCTAssertEqual(resolver.apiKey(), Self.sampleKey)
        XCTAssertEqual(resolver.status(), .configured(.environment))
    }

    func testTheKeychainIsUsedWhenThereIsNoEnvironmentVariable() {
        let store = InMemoryAPICredentialStore(credential: Self.sampleKey)
        let resolver = OpenAICredentialResolver(store: store, environment: { [:] })

        XCTAssertEqual(resolver.apiKey(), Self.sampleKey)
        XCTAssertEqual(resolver.status(), .configured(.keychain))
    }

    func testNoCredentialAnywhereReportsNotConfigured() {
        let resolver = OpenAICredentialResolver(store: InMemoryAPICredentialStore(), environment: { [:] })

        XCTAssertNil(resolver.apiKey())
        XCTAssertEqual(resolver.status(), .notConfigured)
        XCTAssertFalse(resolver.status().isConfigured)
    }

    /// A blank environment variable is not a credential, and must not shadow a real stored key.
    func testABlankEnvironmentVariableFallsThroughToTheKeychain() {
        let store = InMemoryAPICredentialStore(credential: Self.sampleKey)
        let resolver = OpenAICredentialResolver(store: store, environment: { ["OPENAI_API_KEY": "   "] })

        XCTAssertEqual(resolver.apiKey(), Self.sampleKey)
        XCTAssertEqual(resolver.status(), .configured(.keychain))
    }

    /// A Keychain that cannot be read is reported as such, not as "you have no key" — which would
    /// send the user off to re-enter a key they already have.
    func testAnUnreadableKeychainIsDistinctFromHavingNoKey() {
        let store = InMemoryAPICredentialStore(failure: .accessDenied)
        let resolver = OpenAICredentialResolver(store: store, environment: { [:] })

        XCTAssertEqual(resolver.status(), .unavailable)
        XCTAssertNil(resolver.apiKey(), "At request time there is still no usable key.")
    }

    func testTheEnvironmentStillWorksEvenWhenTheKeychainIsBroken() {
        let store = InMemoryAPICredentialStore(failure: .unavailable(status: errSecIO))
        let resolver = OpenAICredentialResolver(store: store, environment: { ["OPENAI_API_KEY": Self.sampleKey] })

        XCTAssertEqual(resolver.apiKey(), Self.sampleKey)
        XCTAssertEqual(resolver.status(), .configured(.environment))
    }

    // MARK: - One source for both providers

    /// Transcription and extraction must never end up on different keys — that shows up as one half
    /// of the pipeline mysteriously failing.
    func testTranscriptionAndExtractionResolveThroughTheSameSource() {
        let store = InMemoryAPICredentialStore(credential: Self.sampleKey)
        let resolver = OpenAICredentialResolver(store: store, environment: { [:] })
        let provider = resolver.apiKeyProvider()

        let transcription = OpenAITranscriptionProvider(apiKeyProvider: provider)
        let extractor = OpenAIWorkStateExtractor(apiKeyProvider: provider)
        XCTAssertNotNil(transcription)
        XCTAssertNotNil(extractor)

        XCTAssertEqual(provider(), Self.sampleKey)

        // Replacing the key moves both at once, because there is only one place to change.
        try? store.save(Self.otherKey)
        XCTAssertEqual(provider(), Self.otherKey)
    }

    /// The environment reader used by the resolver is the same one the existing tests and live-test
    /// harness use, so the two paths cannot drift apart.
    func testTheEnvironmentPathIsTheExistingConfigurationReader() {
        XCTAssertNil(OpenAIConfiguration.apiKey(from: [:]))
        XCTAssertNil(OpenAIConfiguration.apiKey(from: ["OPENAI_API_KEY": "   "]))
        XCTAssertEqual(OpenAIConfiguration.apiKey(from: ["OPENAI_API_KEY": " abc "]), "abc")

        let resolver = OpenAICredentialResolver(
            store: InMemoryAPICredentialStore(),
            environment: { ["OPENAI_API_KEY": " abc "] }
        )
        XCTAssertEqual(resolver.apiKey(), "abc")
    }

    // MARK: - The key must not leak

    /// A secret that turns up in a log, a crash report, or an error string is a secret that has
    /// left the machine.
    func testTheCredentialNeverAppearsInErrorsOrDescriptions() {
        let errors: [CredentialStoreError] = [
            .accessDenied,
            .unavailable(status: errSecIO),
            .blankCredential
        ]
        for error in errors {
            XCTAssertFalse(String(describing: error).contains(Self.sampleKey))
        }

        let statuses: [CredentialStatus] = [.notConfigured, .configured(.keychain), .configured(.environment), .unavailable]
        for status in statuses {
            XCTAssertFalse(String(describing: status).contains(Self.sampleKey))
        }

        let results: [CredentialVerificationResult] = [
            .valid, .unauthorized, .forbidden, .rateLimitedOrBillingIssue, .networkUnavailable, .unexpected(status: 500)
        ]
        for result in results {
            XCTAssertFalse(String(describing: result).contains(Self.sampleKey))
        }
    }

    /// The status the UI renders describes the source, never the value.
    func testTheStatusTypeCarriesNoCredential() {
        let store = InMemoryAPICredentialStore(credential: Self.sampleKey)
        let resolver = OpenAICredentialResolver(store: store, environment: { [:] })

        XCTAssertFalse(String(describing: resolver.status()).contains(Self.sampleKey))
    }

    /// Nothing in the app's persisted models can carry the key: the stores are typed, and none of
    /// those types has a field for it.
    func testTheCredentialCannotReachTheProjectOrProfileFiles() throws {
        let profile = LocalUserProfile(
            id: UUID(),
            displayName: "이헌득",
            linkedParticipantIDs: [UUID()],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        let profileJSON = try XCTUnwrap(String(data: try encoder.encode(profile), encoding: .utf8))
        XCTAssertFalse(profileJSON.contains(Self.sampleKey))
        XCTAssertFalse(profileJSON.lowercased().contains("apikey"))

        let storeJSON = try XCTUnwrap(
            String(data: try encoder.encode(ProjectStoreFile(projects: [])), encoding: .utf8)
        )
        XCTAssertFalse(storeJSON.lowercased().contains("apikey"))
        XCTAssertFalse(storeJSON.lowercased().contains("openai"))
    }

    // MARK: - Verification

    func testHTTPStatusesMapToDistinctVerificationResults() {
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 200), .valid)
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 204), .valid)
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 401), .unauthorized)
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 403), .forbidden)
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 429), .rateLimitedOrBillingIssue)
        XCTAssertEqual(OpenAICredentialVerifier.result(for: 500), .unexpected(status: 500))
    }

    /// The check is authentication-only by construction: a model-listing endpoint runs no model, so
    /// pressing 연결 확인 cannot bill the user.
    func testVerificationUsesAnEndpointThatRunsNoModel() {
        let endpoint = OpenAICredentialVerifier.endpoint.absoluteString
        XCTAssertEqual(endpoint, "https://api.openai.com/v1/models")
        XCTAssertFalse(endpoint.contains("responses"))
        XCTAssertFalse(endpoint.contains("completions"))
        XCTAssertFalse(endpoint.contains("transcriptions"))
    }

    /// Verification reads; it must never write. A failed check on a mistyped key must leave the
    /// working key the user already saved exactly where it was.
    func testAFailedVerificationLeavesTheStoredKeyUntouched() async throws {
        let store = InMemoryAPICredentialStore(credential: Self.sampleKey)
        let verifier = StubVerifier(result: .unauthorized)

        let result = await verifier.verify("sk-mistyped")

        XCTAssertEqual(result, .unauthorized)
        XCTAssertEqual(try store.credential(), Self.sampleKey)
    }

    /// Saving without verifying is allowed on purpose: the user may be offline, the key is theirs,
    /// and refusing to store it would make the app unusable for a reason that is not the app's to
    /// decide. This test pins that decision so it cannot change by accident.
    func testAnUnverifiedKeyCanStillBeSaved() throws {
        let store = InMemoryAPICredentialStore()
        let resolver = OpenAICredentialResolver(store: store, environment: { [:] })

        try resolver.save(Self.sampleKey)

        XCTAssertEqual(resolver.status(), .configured(.keychain))
        XCTAssertEqual(try store.credential(), Self.sampleKey)
    }

    func testResolverRefusesToSaveABlankKey() {
        let resolver = OpenAICredentialResolver(store: InMemoryAPICredentialStore(), environment: { [:] })
        XCTAssertThrowsError(try resolver.save("   ")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .blankCredential)
        }
    }

    // MARK: - Guidance

    /// The cost and privacy notices are the whole reason a BYOK screen is honest. Losing one would
    /// be silent, so their presence is asserted rather than trusted.
    func testTheSettingsScreenStatesCostAndPrivacy() {
        let text = AISettingsView.guidanceLines.joined(separator: "\n")
        XCTAssertTrue(text.contains("BYOK"))
        XCTAssertTrue(text.contains("ChatGPT"))
        XCTAssertTrue(text.contains("사용료"))
        XCTAssertTrue(text.contains("본인 계정"))
        XCTAssertTrue(text.contains("한도"))
        XCTAssertTrue(text.contains("OpenAI로 전송"))
        XCTAssertTrue(text.contains("삭제해도"))
    }
}

/// Answers with a canned result. The real verifier is never used in tests — it would make a network
/// call, and a test run must not.
private struct StubVerifier: OpenAICredentialVerifying {
    let result: CredentialVerificationResult

    func verify(_ credential: String) async -> CredentialVerificationResult {
        result
    }
}
