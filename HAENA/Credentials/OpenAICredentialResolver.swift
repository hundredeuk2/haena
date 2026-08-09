import Foundation

/// Where a credential came from. Shown to the user so they can tell why the app is working — or
/// why a key they just saved is not being used, because an environment variable is winning.
///
/// The source is safe to display. The key never is, and is deliberately not part of this type.
enum CredentialSource: Equatable, Sendable {
    case environment
    case keychain
}

/// What the settings screen needs to know, and nothing more.
enum CredentialStatus: Equatable, Sendable {
    case notConfigured
    case configured(CredentialSource)
    /// The Keychain could not be read. Distinct from "not configured": the user may well have a
    /// key saved, and telling them they have none would send them to re-enter it for no reason.
    case unavailable

    var isConfigured: Bool {
        if case .configured = self {
            return true
        }
        return false
    }
}

/// The single place the app decides which OpenAI credential to use.
///
/// Transcription and Work State Extraction both go through this, so the app cannot end up
/// transcribing with one key and extracting with another — which would show up as one half of the
/// pipeline mysteriously failing.
///
/// Priority is environment first, then Keychain. That order is for the person developing and
/// testing the app: an `OPENAI_API_KEY` in the shell is an explicit, temporary, per-process
/// override, and it would be surprising for a stored key to silently beat it. For a user who
/// installed a DMG there is no environment variable, so the Keychain is simply where their key is.
struct OpenAICredentialResolver: Sendable {
    let store: any APICredentialStore
    let environment: @Sendable () -> [String: String]

    init(
        store: any APICredentialStore,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.store = store
        self.environment = environment
    }

    /// The app's default: the real Keychain and the real process environment.
    static let shared = OpenAICredentialResolver(store: KeychainAPICredentialStore())

    /// The key to use, or nil when there is none. A Keychain failure is treated as "no key from the
    /// Keychain" here rather than being thrown: at request time the useful answer is the same
    /// (there is no credential), and the settings screen reports the failure properly.
    func apiKey() -> String? {
        if let fromEnvironment = OpenAIConfiguration.apiKey(from: environment()) {
            return fromEnvironment
        }
        return try? store.credential().flatMap(CredentialNormalisation.normalised)
    }

    /// Which source is in play, for display. Never returns the key.
    func status() -> CredentialStatus {
        if OpenAIConfiguration.apiKey(from: environment()) != nil {
            return .configured(.environment)
        }
        do {
            if let stored = try store.credential(), CredentialNormalisation.normalised(stored) != nil {
                return .configured(.keychain)
            }
            return .notConfigured
        } catch {
            return .unavailable
        }
    }

    /// A closure the providers can hold. Handed out rather than letting each provider build its own
    /// resolver, so there is exactly one answer to "which key".
    func apiKeyProvider() -> @Sendable () -> String? {
        let resolver = self
        return { resolver.apiKey() }
    }

    // MARK: - Writing

    func save(_ credential: String) throws {
        guard CredentialNormalisation.normalised(credential) != nil else {
            throw CredentialStoreError.blankCredential
        }
        try store.save(credential)
    }

    func delete() throws {
        try store.delete()
    }
}
