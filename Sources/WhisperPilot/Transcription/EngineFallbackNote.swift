import Foundation

/// Builds the overlay note shown when the high-accuracy speech engine (Parakeet)
/// could not start and an Apple engine took over.
enum EngineFallbackNote {
    static func text(for error: Error) -> String {
        "⚠️ Couldn't start the high-accuracy speech model (\(reason(for: error))). Using Apple's on-device engine instead, so accuracy may be lower. Whisper Pilot tries the better model again next time you press Play."
    }

    static func reason(for error: Error) -> String {
        if let urlError = urlError(in: error) {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "no internet connection for the one-time model download"
            case .timedOut:
                return "the one-time model download timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "can't reach the model server"
            default:
                return "the one-time model download failed"
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "unknown error" : message
    }

    private static func urlError(in error: Error) -> URLError? {
        if let urlError = error as? URLError { return urlError }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return URLError(URLError.Code(rawValue: ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return urlError(in: underlying) }
        return nil
    }
}
