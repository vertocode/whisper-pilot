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
    /// macOS is older than 26.0, so the API this app relies on doesn't exist.
    /// See `TranslationSupport.isAvailable` for why the floor is 26 and not 15.
    case unavailableOnThisSystem
}

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
    /// The feature floor is macOS 26.0, not the framework's own 15.0. Reasons,
    /// all verified against the SDK:
    ///
    /// - `TranslationSession(installedSource:target:)` — the only way to own a
    ///   session from an actor rather than a SwiftUI view — is 26.0+.
    /// - `session.cancel()`, `session.isReady`, and `TranslationError
    ///   .notInstalled` are all 26.0+, and the download UX needs them.
    /// - `Strategy.lowLatency`, which is the entire point of a live-caption
    ///   feature, is 26.4+.
    ///
    /// On 15.0–25.x the session can only be obtained through the SwiftUI
    /// `.translationTask` modifier, which would mean hoisting a service into a
    /// view and shipping a degraded version of the feature besides. Not worth
    /// two code paths — see docs/ARCHITECTURE.md on wiring living in one place.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
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
        guard #available(macOS 26.0, *) else { return .unavailableOnThisSystem }
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
        guard #available(macOS 26.0, *) else { return [] }
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
