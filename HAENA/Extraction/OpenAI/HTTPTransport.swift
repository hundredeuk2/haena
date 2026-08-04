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
