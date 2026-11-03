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

/// Every model Whisper Pilot can talk to. The lists come from the providers' own model APIs
/// (see `AIModelCatalog`); the built-in rows below are the fallback. Order within each
/// vendor controls picker order.
///
/// Default behavior on first launch and on bogus stored selections: pick the
/// first model whose vendor has a configured API key (see `defaultModel(for:)`).
enum AIModelRegistry {
    /// Built-in list, used only when a provider's model list has not been fetched (no key yet,
    /// offline, or the request failed). Ids here are the newest known ones; the fetched list
    /// replaces them as soon as the provider answers.
    static let all: [AIModel] = [
        // Gemini — order is cheap-first so the auto-fallback on 404 lands on
        // the closest-equivalent option (see `AppCoordinator.aiFallbackChain`).
        AIModel(id: "gemini-2.5-flash",       vendor: .gemini,    displayName: "Gemini 2.5 Flash",       tagline: "fast, recommended default"),
        AIModel(id: "gemini-2.5-flash-lite",  vendor: .gemini,    displayName: "Gemini 2.5 Flash Lite",  tagline: "cheapest, lowest latency"),
        AIModel(id: "gemini-2.5-pro",         vendor: .gemini,    displayName: "Gemini 2.5 Pro",         tagline: "highest quality, slower"),
        // Claude — most-capable last so the picker reads cheap → expensive.
        AIModel(id: "claude-haiku-5-5",       vendor: .anthropic, displayName: "Claude Haiku 5.5",       tagline: "fast, cheapest Claude"),
        AIModel(id: "claude-sonnet-5-5",      vendor: .anthropic, displayName: "Claude Sonnet 5.5",      tagline: "balanced, recommended default"),
        AIModel(id: "claude-opus-5-5",        vendor: .anthropic, displayName: "Claude Opus 5.5",        tagline: "highest quality, slower"),
        AIModel(id: "claude-fable-5-1",       vendor: .anthropic, displayName: "Claude Fable 5.1",       tagline: "most capable"),
    ]

    /// Older ids that stay valid for a saved selection or a resumed session, but are no longer offered.
    static let retired: [AIModel] = [
        AIModel(id: "gemini-2.0-flash",       vendor: .gemini,    displayName: "Gemini 2.0 Flash",       tagline: nil),
        AIModel(id: "gemini-2.0-flash-lite",  vendor: .gemini,    displayName: "Gemini 2.0 Flash Lite",  tagline: nil),
        AIModel(id: "claude-haiku-4-5",       vendor: .anthropic, displayName: "Claude Haiku 4.5",       tagline: nil),
        AIModel(id: "claude-sonnet-4-6",      vendor: .anthropic, displayName: "Claude Sonnet 4.6",      tagline: nil),
        AIModel(id: "claude-opus-4-7",        vendor: .anthropic, displayName: "Claude Opus 4.7",        tagline: nil),
    ]

    /// Short note for a model id, taken from the built-in list so fetched models keep it.
    static func staticTagline(for id: String) -> String? {
        all.first { $0.id == id }?.tagline
    }

    /// What the pickers show for a vendor: the list fetched from the provider when there is one,
    /// otherwise the built-in list.
    static func models(for vendor: AIVendor, catalog: ModelCatalogStore = .shared) -> [AIModel] {
        catalog.models(for: vendor) ?? staticModels(for: vendor)
    }

    static func staticModels(for vendor: AIVendor) -> [AIModel] {
        all.filter { $0.vendor == vendor }
    }

    /// Finds a model by id in the fetched lists first, then the built-in and retired ones, so a saved
    /// selection keeps working whichever list it came from.
    static func model(for id: String, catalog: ModelCatalogStore = .shared) -> AIModel? {
        for vendor in AIVendor.allCases {
            if let found = catalog.models(for: vendor)?.first(where: { $0.id == id }) { return found }
        }
        return all.first { $0.id == id } ?? retired.first { $0.id == id }
    }

    /// Best-effort default given which vendors have keys configured. Used by
    /// `SettingsStore` on first launch (no stored selection) and as a fallback
    /// when the user clears the API key for whichever vendor was active.
    /// Order: Gemini first if available (matches the v0.1.x default), then
    /// Claude, then a fall-through to the first registered model. Always from
    /// the built-in list, so the default is a model we know the purpose of.
    static func defaultModel(availableVendors: Set<AIVendor>) -> AIModel {
        if availableVendors.contains(.gemini),
           let m = staticModels(for: .gemini).first {
            return m
        }
        if availableVendors.contains(.anthropic),
           let m = staticModels(for: .anthropic).first {
            return m
        }
        return all[0]
    }
}
