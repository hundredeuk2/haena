import Foundation

/// The outcome of asking OpenAI whether a key works.
///
/// Separated by cause because the fixes are completely different: a wrong key is retyped, a
/// rate-limited or unpaid account is fixed on OpenAI's site, and a network failure just needs
/// trying again.
enum CredentialVerificationResult: Equatable, Sendable {
    case valid
    /// 401 — the key is wrong, revoked, or for a different account.
    case unauthorized
    /// 403 — the key is real but not allowed to do this, e.g. a project key with no permissions.
    case forbidden
    /// 429 — rate limited, or the account has no remaining quota or billing set up.
    case rateLimitedOrBillingIssue
    case networkUnavailable
    case unexpected(status: Int)
}

protocol OpenAICredentialVerifying: Sendable {
    func verify(_ credential: String) async -> CredentialVerificationResult
}

/// Checks a key by listing models.
///
/// `GET /v1/models` is chosen deliberately: it is authenticated, so it proves the key works, but it
/// runs no model and consumes no tokens — so pressing "연결 확인" cannot cost the user anything.
/// Nothing here is sent to a completion endpoint, and no meeting content is involved.
///
/// This type is never exercised by the default test suite; only the injected double is. Verifying a
/// key is a real network call, and a test run must not make one.
struct OpenAICredentialVerifier: OpenAICredentialVerifying {
    static let endpoint = URL(string: "https://api.openai.com/v1/models")!

    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval

    init(
        endpoint: URL = OpenAICredentialVerifier.endpoint,
        session: URLSession = .shared,
        timeout: TimeInterval = 20
    ) {
        self.endpoint = endpoint
        self.session = session
        self.timeout = timeout
    }

    func verify(_ credential: String) async -> CredentialVerificationResult {
        guard let key = CredentialNormalisation.normalised(credential) else {
            return .unauthorized
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkUnavailable
            }
            return Self.result(for: http.statusCode)
        } catch {
            // The response body is never read on failure: it can echo request headers, and those
            // carry the key.
            return .networkUnavailable
        }
    }

    static func result(for statusCode: Int) -> CredentialVerificationResult {
        switch statusCode {
        case 200...299:
            return .valid
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 429:
            return .rateLimitedOrBillingIssue
        default:
            return .unexpected(status: statusCode)
        }
    }
}
