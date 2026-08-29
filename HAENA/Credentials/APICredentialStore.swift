import Foundation

/// Why a credential could not be read or written.
///
/// No case carries the credential, the Keychain query, or an OS error string that might quote
/// either. An error about a secret must not become a way to print the secret.
enum CredentialStoreError: Error, Equatable, Sendable {
    /// The Keychain refused because the user declined the prompt, or the item is not accessible
    /// while the machine is locked. Distinct from a broken Keychain: nothing is wrong, the user
    /// simply said no.
    case accessDenied
    /// A credential is stored, but reading it would require the user to answer a system prompt.
    /// Distinct from `accessDenied`: nobody has said no yet, and distinct from "not configured":
    /// the item is there. The only honest thing a background caller can do with this is stop and
    /// tell the user where to go.
    case interactionRequired
    /// The Keychain itself failed. `status` is an OSStatus code, which describes the failure and
    /// never the item's contents.
    case unavailable(status: Int32)
    /// A blank credential. Refused rather than stored, so "configured" never means "configured
    /// with nothing".
    case blankCredential
}

/// Where the app's provider credentials live.
///
/// Synchronous because the Keychain is, and because the transcription and extraction providers ask
/// for a key at the moment they build a request. Deliberately tiny: one secret, four operations,
/// no notion of accounts or multiple providers.
protocol APICredentialStore: Sendable {
    /// The stored credential, or nil when nothing has been saved. Nil is a normal state.
    ///
    /// **May block on a system prompt.** Only call this from a path the user just asked for, where
    /// a prompt is an expected part of what they started — in this app, the settings screen.
    func credential() throws -> String?
    /// The stored credential without ever putting a prompt on screen.
    ///
    /// Throws `.interactionRequired` when an item exists but reading it needs the user, so a
    /// background caller can end finitely instead of waiting on a window it did not ask for.
    func credentialWithoutInteraction() throws -> String?
    /// Saves or replaces. Callers do not need to know which — an existing item is updated in place
    /// rather than duplicated.
    func save(_ credential: String) throws
    func delete() throws
}

/// The one place the Keychain item is named.
///
/// Kept out of the store type so that a future second credential cannot silently reuse this one's
/// slot, and so the names can be asserted in a test rather than living as string literals inside a
/// Security-framework call.
enum CredentialItem: Equatable, Sendable {
    static let service = "com.haena.HAENA"

    enum Account {
        static let openAI = "openai-api-key"
    }
}

/// Test/dev-only store. Used by the app only under UI test, so an automated run can never read or
/// overwrite the real user's Keychain.
final class InMemoryAPICredentialStore: APICredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    /// Set by a test to make every operation fail, for exercising the error paths.
    private var failure: CredentialStoreError?
    /// Set by a test to make only the non-interactive read fail, so the split between the settings
    /// path and the extraction path can be exercised the way the real Keychain splits it.
    private var nonInteractiveFailure: CredentialStoreError?
    /// How long the reads block, so a test can drive the resolver's finite wait without a Keychain.
    private var readDelay: TimeInterval

    init(
        credential: String? = nil,
        failure: CredentialStoreError? = nil,
        nonInteractiveFailure: CredentialStoreError? = nil,
        readDelay: TimeInterval = 0
    ) {
        stored = credential
        self.failure = failure
        self.nonInteractiveFailure = nonInteractiveFailure
        self.readDelay = readDelay
    }

    func credential() throws -> String? {
        if readDelay > 0 {
            Thread.sleep(forTimeInterval: readDelay)
        }
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        return stored
    }

    func credentialWithoutInteraction() throws -> String? {
        if readDelay > 0 {
            Thread.sleep(forTimeInterval: readDelay)
        }
        lock.lock()
        defer { lock.unlock() }
        if let nonInteractiveFailure {
            throw nonInteractiveFailure
        }
        if let failure {
            throw failure
        }
        return stored
    }

    func save(_ credential: String) throws {
        guard let normalised = CredentialNormalisation.normalised(credential) else {
            throw CredentialStoreError.blankCredential
        }
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        stored = normalised
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        stored = nil
    }
}

/// Trimming and emptiness, in one place, so the store, the resolver, and the settings screen cannot
/// disagree about what counts as a credential.
///
/// Deliberately does **not** validate the shape of the key: prefixes and lengths are the provider's
/// to change, and an app that rejects a key OpenAI would have accepted is worse than one that lets
/// the provider answer.
enum CredentialNormalisation {
    static func normalised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
