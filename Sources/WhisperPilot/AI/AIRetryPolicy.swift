import Foundation

/// Per-attempt bookkeeping for a streaming request. A retry is only safe while
/// nothing has reached the user yet, so providers count deltas here.
final class StreamAttempt: @unchecked Sendable {
    var deltaCount = 0
    var retryAfter: String?
}

/// One bounded retry for transient AI failures (rate limit, server error,
/// dropped connection), and only before the first text arrives.
enum AIRetryPolicy {
    static let maxRetries = 1
    /// Longer server-requested waits are not worth blocking the overlay for.
    static let maxWait: TimeInterval = 8
    private static let baseDelay: TimeInterval = 1
    private static let maxJitter: TimeInterval = 0.5

    /// Seconds to wait before retrying, or nil when the error should surface as is.
    /// `jitter` is 0...1 and spreads out clients that failed at the same moment.
    static func delay(after error: Error, retryAfter: String?, jitter: Double) -> TimeInterval? {
        switch error {
        case GeminiError.http(let status, _), AnthropicError.http(let status, _):
            return delay(forStatus: status, retryAfter: retryAfter, jitter: jitter)
        case AnthropicError.stream(let type, _):
            guard type == "overloaded_error" || type == "api_error" else { return nil }
            return backoff(jitter)
        default:
            guard let urlError = error as? URLError else { return nil }
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed:
                return backoff(jitter)
            default:
                return nil
            }
        }
    }

    static func delay(forStatus status: Int, retryAfter: String?, jitter: Double) -> TimeInterval? {
        guard status == 429 || (500..<600).contains(status) else { return nil }
        if let raw = retryAfter?.trimmingCharacters(in: .whitespaces), let seconds = Double(raw) {
            guard seconds >= 0, seconds <= maxWait else { return nil }
            return seconds
        }
        return backoff(jitter)
    }

    private static func backoff(_ jitter: Double) -> TimeInterval {
        baseDelay + min(max(jitter, 0), 1) * maxJitter
    }

    static func withRetry(
        jitter: () -> Double = { .random(in: 0...1) },
        wait: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onRetry: (TimeInterval, Error) -> Void = { _, _ in },
        _ operation: (StreamAttempt) async throws -> AIFinishReason
    ) async throws -> AIFinishReason {
        var retries = 0
        while true {
            let attempt = StreamAttempt()
            do {
                return try await operation(attempt)
            } catch {
                guard retries < maxRetries,
                      attempt.deltaCount == 0,
                      let delay = delay(after: error, retryAfter: attempt.retryAfter, jitter: jitter()) else {
                    throw error
                }
                retries += 1
                onRetry(delay, error)
                try await wait(delay)
            }
        }
    }
}
