import Foundation
import Translation

/// Whether a given source → target pair can actually be translated on this Mac
/// right now. Deliberately *not* a re-export of `LanguageAvailability.Status`:
/// that type is gated to macOS 15+, and Settings has to render a sensible row on
/// every OS we ship to (the app's deployment target is 14.0).
enum TranslationAvailability: Sendable, Equatable {
    /// Language pack is downloaded — translation works immediately.
    case installed
    /// Apple supports the pair but the pack isn't on disk yet. The Settings tab
    /// offers a Download button for this case.
    case downloadRequired
    /// Apple doesn't ship this pair at all. Nothing the user can do.
    case unsupported
    /// macOS is older than 15.0, where Apple's `Translation` framework doesn't
    /// exist at all.
    case unavailableOnThisSystem
}

/// Minimum macOS version that can translate. The runtime path differs above and
/// below 26.0 (see `AppleTranslationService` vs `SequoiaTranslationService`),
/// but both are the same feature at slightly different speeds.
let translationMinimumMajorVersion = 15

/// Engine-agnostic seam for the translation backend, mirroring how
/// `TranscriptionProvider` and `AIProvider` keep their concrete types out of
/// everything except `AppCoordinator`. Only one conformance exists today
/// (`AppleTranslationService`); a future on-device or hosted translator is one
/// file plus one line in the coordinator.
protocol TranslationProviding: AnyObject, Sendable {
    /// Translates one line. Callers are expected to throttle — see
    /// `TranslationQueue`, which owns the debounce and the ordering guard.
    func translate(_ text: String) async throws -> String
    /// Runs one throwaway translation so the first *real* caption doesn't pay
    /// model-load cost. Measured on an M-series Mac: first call ≈ 834 ms,
    /// steady state ≈ 34 ms. Without this the opening line of every session
    /// lands almost a second late.
    func prewarm() async
}

/// Availability probing that callers can use regardless of OS version. Split
/// out from `AppleTranslationService` because Settings needs to answer "can this
/// Mac do en → pt-BR?" *before* any session exists, and on systems where the
/// session type itself is unavailable.
enum TranslationSupport {
    /// Whether this Mac can translate at all. macOS 15.0 is the floor —
    /// `Translation` doesn't exist below it.
    ///
    /// The runtime path splits at 26.0, because
    /// `TranslationSession(installedSource:target:)` — the only way to own a
    /// session from an actor rather than a SwiftUI view — is 26.0+, as are
    /// `cancel()`, `isReady`, and `TranslationError.notInstalled`. On 15.0-25.x
    /// the session has to come from a `.translationTask` modifier and be handed
    /// in (`SequoiaTranslationService`).
    ///
    /// Everything *else* the feature needs is 15.0+ already: `LanguageAvailability`,
    /// `status(from:to:)`, `supportedLanguages`, `translate(_:)`, and
    /// `prepareTranslation()`. So the Settings tab, the availability checks, and
    /// the language-pack download button work identically on both paths.
    ///
    /// The only user-visible difference is speed. `Strategy.lowLatency` is
    /// 26.4+; below it the engine runs its default (high-fidelity) strategy.
    /// Measured en → pt-BR: ~39 ms per line with `.lowLatency`, ~91 ms without.
    /// Both sit far under the 400 ms stability debounce, so the gap doesn't
    /// reach the user.
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Resolves a stored identifier (`"pt-BR"`) into the framework's language
    /// type. Returns nil for empty/garbage so callers can treat "unset" and
    /// "unparseable" the same way.
    static func language(from identifier: String) -> Locale.Language? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Locale.Language(identifier: trimmed)
    }

    /// True when two identifiers name the same language, ignoring region.
    /// `en-US` → `en-GB` is a no-op worth skipping; `en` → `pt-BR` is not.
    /// Used to auto-disable the feature when the transcription locale and the
    /// translation target agree, rather than burning calls on identity work.
    static func isSameLanguage(_ a: String, _ b: String) -> Bool {
        guard let lhs = language(from: a), let rhs = language(from: b) else { return false }
        return lhs.languageCode?.identifier == rhs.languageCode?.identifier
    }

    /// Asks the framework whether a pair is installed / downloadable / absent.
    static func availability(from source: String, to target: String) async -> TranslationAvailability {
        guard #available(macOS 15.0, *) else { return .unavailableOnThisSystem }
        guard let src = language(from: source), let dst = language(from: target) else {
            return .unsupported
        }
        let status = await LanguageAvailability().status(from: src, to: dst)
        switch status {
        case .installed: return .installed
        case .supported: return .downloadRequired
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Every target language Apple ships a model for, deduplicated to one entry
    /// per language code and sorted by localized name. The Settings picker is
    /// populated from this rather than a hardcoded list, so the options track
    /// whatever the running OS actually supports.
    ///
    /// Returns `[(identifier, localizedName)]` — the identifier is what gets
    /// persisted in `SettingsStore.translationTargetIdentifier`.
    static func supportedTargets() async -> [(identifier: String, name: String)] {
        guard #available(macOS 15.0, *) else { return [] }
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var result: [(identifier: String, name: String)] = []
        for language in languages {
            // `maximalIdentifier` is over-specified for a menu ("en-Latn-US");
            // collapse to the language code, plus region when one is present,
            // so users see "Portuguese (Brazil)" rather than script subtags.
            guard let code = language.languageCode?.identifier else { continue }
            let identifier: String
            if let region = language.region?.identifier {
                identifier = "\(code)-\(region)"
            } else {
                identifier = code
            }
            guard seen.insert(identifier).inserted else { continue }
            let name = Locale.current.localizedString(forIdentifier: identifier)
                ?? Locale.current.localizedString(forLanguageCode: code)
                ?? identifier
            result.append((identifier, name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Apple `Translation` backend. Owns one `TranslationSession` for the lifetime
/// of a listening session, built from a fixed source → target pair decided at
/// session start (the transcription locale and the user's chosen target).
///
/// Deliberately dumb: no debouncing, no ordering, no mode switching. All of that
/// lives in `TranslationQueue`, so this type stays a thin, replaceable adapter
/// over the framework.
@available(macOS 26.0, *)
final class AppleTranslationService: TranslationProviding, @unchecked Sendable {
    private let session: TranslationSession

    /// Builds a session for an *already installed* pair. Callers must check
    /// `TranslationSupport.availability(from:to:) == .installed` first —
    /// `installedSource:` is a contract, not a hint, and a session built for a
    /// missing pack throws `.notInstalled` on every call.
    ///
    /// That same contract is why this init can never trigger a download:
    /// `canRequestDownloads` is false on sessions built this way, verified
    /// across a CLI binary, an accessory app, and a regular app with a key
    /// window. The download flow therefore lives in Settings on the SwiftUI
    /// `.translationTask` path, which does report true.
    init(source: Locale.Language, target: Locale.Language) {
        if #available(macOS 26.4, *) {
            // `.lowLatency` is the whole reason the floor is 26.4-aware. Live
            // captions want speed over fidelity; a paragraph-perfect
            // translation that lands after the speaker moved on is useless.
            self.session = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            self.session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return try await session.translate(trimmed).targetText
    }

    func prewarm() async {
        // Failure here is not interesting — if the pack vanished between the
        // availability check and now, the first real translation reports it.
        _ = try? await session.translate("Hello.")
    }
}

/// macOS 15.0-25.x backend.
///
/// Identical to `AppleTranslationService` in what it does, different only in how
/// it gets a session. Below macOS 26 there is no `installedSource:` init, so the
/// session can only come from SwiftUI's `.translationTask` modifier. A tiny
/// zero-size host view in the overlay owns that modifier and hands the session
/// here via `adopt(_:)`.
///
/// That inverts the usual dependency — a view feeding a service — which is why
/// the 26.0 path exists and is preferred where available. It's confined to this
/// type plus the host view; `TranslationQueue` and the coordinator can't tell
/// the two apart.
///
/// An actor rather than a lock-guarded class because translations can be issued
/// before the view has handed the session over (the queue starts with the
/// session, the view mounts on the next render). Callers await adoption instead
/// of failing, so the opening lines of a meeting aren't silently dropped.
@available(macOS 15.0, *)
actor SequoiaTranslationService: TranslationProviding {
    private var session: TranslationSession?
    private var waiters: [CheckedContinuation<TranslationSession?, Never>] = []
    private var isRelinquished = false

    var hasSession: Bool { session != nil }

    /// Called by the host view when SwiftUI produces a session. Wakes anything
    /// that was queued waiting for one.
    func adopt(_ newSession: TranslationSession) {
        session = newSession
        isRelinquished = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: newSession) }
    }

    /// Called when the host view's task ends (configuration cleared, overlay
    /// gone). Any waiter is released with nil so it fails fast instead of
    /// hanging on a session that will never arrive.
    func relinquish() {
        session = nil
        isRelinquished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let active = await activeSession() else {
            throw TranslationServiceError.sessionUnavailable
        }
        return try await active.translate(trimmed).targetText
    }

    func prewarm() async {
        guard let active = await activeSession() else { return }
        _ = try? await active.translate("Hello.")
    }

    private func activeSession() async -> TranslationSession? {
        if let session { return session }
        if isRelinquished { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Errors this layer raises on its own behalf, as opposed to `TranslationError`
/// coming out of the framework.
enum TranslationServiceError: LocalizedError {
    /// The Sequoia host view never delivered a session, or it was torn down
    /// while a translation was queued behind it.
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "No translation session is active."
        }
    }
}
