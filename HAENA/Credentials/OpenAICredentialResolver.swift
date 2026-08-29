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

/// A one-shot handoff from a task nobody is allowed to wait on.
///
/// Exists because the credential read has to be observable without being awaited: awaiting it is
/// what would reintroduce the unbounded wait. First write wins, so a late answer from an abandoned
/// read cannot overwrite one the caller already acted on.
final class CredentialAnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CredentialResolution?

    var value: CredentialResolution? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ resolution: CredentialResolution) {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return }
        stored = resolution
    }
}

/// The finite answers a background caller can get when it asks for a credential without being
/// willing to put a system prompt in front of the user.
///
/// Four cases rather than an optional, because the three failures need different advice: register a
/// key, go unlock it in settings, or the Keychain is broken. Collapsing them would send a user who
/// already has a key off to create a second one.
enum CredentialResolution: Equatable, Sendable {
    case resolved(String)
    case notConfigured
    case interactionRequired
    case unavailable
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
    /// How long a background credential read may take before the caller stops waiting for it.
    ///
    /// A Keychain read that is going to succeed takes microseconds; one that is going to put a
    /// window on screen takes as long as the person takes to notice it. Seconds is far past the
    /// first and nowhere near the second, so the budget separates them without being a guess about
    /// how fast a Keychain "should" be.
    static let backgroundReadBudget: Duration = .seconds(3)

    let store: any APICredentialStore
    let environment: @Sendable () -> [String: String]
    private let readBudget: Duration

    init(
        store: any APICredentialStore,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        readBudget: Duration = OpenAICredentialResolver.backgroundReadBudget
    ) {
        self.store = store
        self.environment = environment
        self.readBudget = readBudget
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

    // MARK: - Background reads

    /// The credential for work the user did not stand at the screen and ask for, resolved in a
    /// bounded time and reported as a finite outcome either way.
    ///
    /// The environment is checked first and synchronously: it is a process variable, it cannot
    /// block, and it keeps its existing priority over the Keychain.
    ///
    /// The Keychain read is then given `readBudget` and no more. **The read is not cancelled when
    /// the budget runs out** — `SecItemCopyMatching` is a synchronous C call with no cancellation,
    /// and a wrapper that claimed otherwise would be lying. It is left on a detached task to finish
    /// or to sit behind whatever window macOS decided to show, and its answer is discarded. What
    /// the budget buys is not a faster Keychain; it is the guarantee that the caller gets an answer.
    ///
    /// Expiry is reported as `interactionRequired`, never as a credential and never as success.
    func resolveWithoutInteraction() async -> CredentialResolution {
        if let fromEnvironment = OpenAIConfiguration.apiKey(from: environment()) {
            return .resolved(fromEnvironment)
        }

        let store = store
        let answer = CredentialAnswerBox()
        // Fire and forget, deliberately. Nothing below ever awaits this task: a structured child or
        // an `await task.value` would make the caller wait for it after all, because a task blocked
        // in `SecItemCopyMatching` cannot be cancelled and a parent cannot return while a child it
        // awaits is outstanding. That mistake is exactly what this method exists to avoid.
        Task.detached(priority: .userInitiated) {
            do {
                guard let stored = try store.credentialWithoutInteraction(),
                      let normalised = CredentialNormalisation.normalised(stored) else {
                    answer.set(.notConfigured)
                    return
                }
                answer.set(.resolved(normalised))
            } catch CredentialStoreError.interactionRequired, CredentialStoreError.accessDenied {
                answer.set(.interactionRequired)
            } catch {
                answer.set(.unavailable)
            }
        }

        // Poll rather than await, for the same reason: this loop must be able to give up, and
        // giving up must not be conditional on the thing it is waiting for.
        let deadline = ContinuousClock.now.advanced(by: readBudget)
        while ContinuousClock.now < deadline {
            if let resolved = answer.value {
                return resolved
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return answer.value ?? .interactionRequired
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
