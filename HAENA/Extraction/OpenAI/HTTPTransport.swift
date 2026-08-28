import Foundation

/// The one place a provider adapter touches the network, kept behind a protocol so adapter tests
/// can drive every branch — 401, 429, 5xx, timeout, malformed body — without an API key, a network
/// connection, or a real request ever leaving the machine.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport. Uses an ephemeral session so nothing about a request or its response is
/// written to a shared on-disk URL cache.
struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    init(requestTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkStateExtractionError.malformedResponse
        }
        return (data, httpResponse)
    }
}

#if DEBUG
/// Refuses every request instead of sending it.
///
/// Exists for one narrow job: a Debug run that deliberately reproduces a *pre-network* failure, in
/// which "no request left the machine" is part of what is being verified. Asserting that from the
/// outside is awkward — absence of a packet is hard to prove after the fact — so the run installs a
/// transport that cannot produce one, and the refusal is recorded as a fact instead.
///
/// Fail-closed by construction: there is no allow-list, no host matching, and no pass-through
/// branch that a mistake could fall into. Every request is refused, whatever it is addressed to.
///
/// Wrapped in `#if DEBUG` so it is not compiled into a Release binary at all. The production
/// credential and provider contracts are untouched by its existence — this is a transport swap at
/// assembly time and nothing else.
struct FailClosedHTTPTransport: HTTPTransport {
    /// Set when a request was attempted, so a run can report "the network layer was never reached"
    /// as an observation rather than an assumption. Never holds the request itself: a refused
    /// request still carries an Authorization header and the user's transcript.
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var refused = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return refused
        }

        func record() {
            lock.lock()
            defer { lock.unlock() }
            refused += 1
        }
    }

    let attempts: Attempts

    init(attempts: Attempts = Attempts()) {
        self.attempts = attempts
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        attempts.record()
        throw WorkStateExtractionError.networkUnavailable
    }
}

extension FailClosedHTTPTransport {
    /// The launch switch that installs this transport. Debug-only, opt-in, and off unless a run
    /// sets it explicitly.
    static let environmentKey = "HAENA_BLOCK_PROVIDER_NETWORK"

    static func isRequested(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}
#endif
