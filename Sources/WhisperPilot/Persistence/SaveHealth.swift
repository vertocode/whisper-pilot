import Foundation

/// Tracks whether writes to the session folder are working, so the overlay can
/// tell the user when a session has stopped being saved (and when it recovers).
struct SaveHealth {
    enum Change: Equatable {
        case none
        case started(reason: String)
        case recovered
    }

    private(set) var failureReason: String?

    var isFailing: Bool { failureReason != nil }

    /// Only the first failure and the first success after it report a change,
    /// so callers can post one banner instead of one per write.
    mutating func record(_ result: Result<Void, Error>) -> Change {
        switch result {
        case .success:
            guard failureReason != nil else { return .none }
            failureReason = nil
            return .recovered
        case .failure(let error):
            let wasFailing = failureReason != nil
            let reason = Self.reason(for: error)
            failureReason = reason
            return wasFailing ? .none : .started(reason: reason)
        }
    }

    static func bannerText(reason: String) -> String {
        "⚠️ Can't save this session: \(reason). New transcript lines and chat are not being saved. Whisper Pilot keeps trying and will tell you when saving works again."
    }

    static let recoveredText = "✅ Saving works again. Anything said while it was failing was not saved."

    static func reason(for error: Error) -> String {
        let ns = error as NSError
        let posix = ns.domain == NSPOSIXErrorDomain
            ? Int32(ns.code)
            : ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil })

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "the disk is full"
            case NSFileWriteNoPermissionError: return "Whisper Pilot has no permission to write to the session folder"
            case NSFileWriteVolumeReadOnlyError: return "the disk is read-only"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "the session folder was moved or deleted"
            default: break
            }
        }
        switch posix {
        case ENOSPC?, EDQUOT?: return "the disk is full"
        case EACCES?, EPERM?: return "Whisper Pilot has no permission to write to the session folder"
        case EROFS?: return "the disk is read-only"
        case ENOENT?: return "the session folder was moved or deleted"
        default: break
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "unknown error" : message
    }
}
