import Foundation
import SwiftUI

/// Provider behind a given model. Used by `SettingsStore` to know which API key
/// to feed in, and by `AppCoordinator` to know which concrete `AIProvider`
/// implementation to instantiate.
enum AIVendor: String, Codable, Sendable, CaseIterable {
    case gemini
    case anthropic

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .anthropic: return "Claude"
        }
    }

    /// Accent color used by UI chips (overlay model selector, Sessions row
    /// badge) so the active vendor is recognizable at a glance — blue ≈
    /// Google's Gemini brand, orange ≈ Anthropic's Claude brand. SwiftUI
    /// system colors are used so they adapt to light/dark mode automatically.
    var accentColor: Color {
        switch self {
        case .gemini: return .blue
        case .anthropic: return .orange
        }
    }
}

/// One row in the unified model picker. The `id` is the wire identifier sent
/// to the provider's API (e.g. "gemini-2.5-flash" or "claude-sonnet-4-6"), and
/// also the canonical key used to persist a selection in UserDefaults or
/// SessionMeta. Display fields are for the SwiftUI picker only.
struct AIModel: Identifiable, Hashable, Sendable {
    let id: String
    let vendor: AIVendor
    let displayName: String
    /// Optional one-line annotation shown under the model name in the picker
    /// (e.g. "fast", "highest quality"). Keep it short — picker rows are
    /// narrow. Nil = no annotation.
    let tagline: String?
}

/// Static catalog of every model Whisper Pilot can talk to. Order within each
/// vendor controls picker order. Adding a new model means appending a row here
/// and shipping — no other code needs to know the model id exists.
///
/// Default behavior on first launch and on bogus stored selections: pick the
/// first model whose vendor has a configured API key (see `defaultModel(for:)`).
enum AIModelRegistry {
    static let all: [AIModel] = [
        // Gemini — order is cheap-first so the auto-fallback on 404 lands on
        // the closest-equivalent option (see `AppCoordinator.aiFallbackChain`).
        AIModel(id: "gemini-2.5-flash",       vendor: .gemini,    displayName: "Gemini 2.5 Flash",       tagline: "fast, recommended default"),
        AIModel(id: "gemini-2.0-flash-lite",  vendor: .gemini,    displayName: "Gemini 2.0 Flash Lite",  tagline: "cheapest, lowest latency"),
        AIModel(id: "gemini-2.5-pro",         vendor: .gemini,    displayName: "Gemini 2.5 Pro",         tagline: "highest quality, slower"),
        AIModel(id: "gemini-2.0-flash",       vendor: .gemini,    displayName: "Gemini 2.0 Flash",       tagline: "legacy"),
        // Claude — most-capable last so the picker reads cheap → expensive.
        AIModel(id: "claude-haiku-4-5",       vendor: .anthropic, displayName: "Claude Haiku 4.5",       tagline: "fast, cheapest Claude"),
        AIModel(id: "claude-sonnet-4-6",      vendor: .anthropic, displayName: "Claude Sonnet 4.6",      tagline: "balanced, recommended default"),
        AIModel(id: "claude-opus-4-7",        vendor: .anthropic, displayName: "Claude Opus 4.7",        tagline: "highest quality, slower"),
    ]

    /// Vendor-keyed view of `all` for picker grouping.
    static func models(for vendor: AIVendor) -> [AIModel] {
        all.filter { $0.vendor == vendor }
    }

    static func model(for id: String) -> AIModel? {
        all.first { $0.id == id }
    }

    /// Best-effort default given which vendors have keys configured. Used by
    /// `SettingsStore` on first launch (no stored selection) and as a fallback
    /// when the user clears the API key for whichever vendor was active.
    /// Order: Gemini first if available (matches the v0.1.x default), then
    /// Claude, then a fall-through to the first registered model.
    static func defaultModel(availableVendors: Set<AIVendor>) -> AIModel {
        if availableVendors.contains(.gemini),
           let m = models(for: .gemini).first {
            return m
        }
        if availableVendors.contains(.anthropic),
           let m = models(for: .anthropic).first {
            return m
        }
        return all[0]
    }
}
