import Combine
import Foundation

/// Reads the model lists the providers return from their "list models" endpoints.
enum ModelListParser {
    struct Page: Equatable {
        var models: [AIModel]
        /// Cursor for the next request. Nil on the last page.
        var next: String?
    }

    private struct AnthropicList: Decodable {
        struct Item: Decodable {
            let id: String
            let display_name: String?
        }
        let data: [Item]
        let has_more: Bool?
        let last_id: String?
    }

    private struct GeminiList: Decodable {
        struct Item: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [Item]?
        let nextPageToken: String?
    }

    static func parseAnthropic(_ data: Data) throws -> Page {
        let list = try JSONDecoder().decode(AnthropicList.self, from: data)
        let models = list.data
            .filter { $0.id.hasPrefix("claude-") }
            .map { item in
                AIModel(
                    id: item.id,
                    vendor: .anthropic,
                    displayName: nonEmpty(item.display_name) ?? item.id,
                    tagline: AIModelRegistry.staticTagline(for: item.id)
                )
            }
        let next = list.has_more == true ? nonEmpty(list.last_id) : nil
        return Page(models: models, next: next)
    }

    /// Only models that can write text: Gemini's list also holds embedding, image, speech and
    /// live-audio models that this app cannot use.
    static func parseGemini(_ data: Data) throws -> Page {
        let list = try JSONDecoder().decode(GeminiList.self, from: data)
        let unusable = ["embedding", "-tts", "-image", "-live", "-audio", "imagen", "veo", "aqa", "learnlm", "robotics", "computer-use"]
        let models = (list.models ?? []).compactMap { item -> AIModel? in
            let id = item.name.hasPrefix("models/") ? String(item.name.dropFirst("models/".count)) : item.name
            guard id.hasPrefix("gemini-"),
                  item.supportedGenerationMethods?.contains("generateContent") == true,
                  !unusable.contains(where: { id.contains($0) }) else { return nil }
            return AIModel(
                id: id,
                vendor: .gemini,
                displayName: nonEmpty(item.displayName) ?? id,
                tagline: AIModelRegistry.staticTagline(for: id)
            )
        }
        return Page(models: models, next: nonEmpty(list.nextPageToken))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

enum ModelListError: Error, Equatable, LocalizedError {
    case http(Int)
    case badResponse
    case empty

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "the API key was refused"
        case .http(let status): return "the server answered HTTP \(status)"
        case .badResponse: return "the answer could not be read"
        case .empty: return "the list was empty"
        }
    }
}

/// Asks a provider which models the API key can use. The network call is injected so tests
/// can feed it canned pages.
struct ModelListFetcher: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var transport: Transport = { request in try await URLSession.shared.data(for: request) }
    /// A guard against a server that never stops saying "there is more".
    static let maxPages = 10

    func fetch(vendor: AIVendor, apiKey: String) async throws -> [AIModel] {
        var models: [AIModel] = []
        var seen = Set<String>()
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let request = Self.request(vendor: vendor, apiKey: apiKey, cursor: cursor)
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw ModelListError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw ModelListError.http(http.statusCode) }
            let page: ModelListParser.Page
            do {
                switch vendor {
                case .anthropic: page = try ModelListParser.parseAnthropic(data)
                case .gemini: page = try ModelListParser.parseGemini(data)
                }
            } catch {
                throw ModelListError.badResponse
            }
            for model in page.models where seen.insert(model.id).inserted { models.append(model) }
            guard let next = page.next else { break }
            cursor = next
        }
        guard !models.isEmpty else { throw ModelListError.empty }
        return models
    }

    static func request(vendor: AIVendor, apiKey: String, cursor: String?) -> URLRequest {
        var components: URLComponents
        switch vendor {
        case .anthropic:
            components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
        case .gemini:
            components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        switch vendor {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }
}

/// The model lists last fetched from each provider, kept in UserDefaults so they survive a
/// restart. Safe to read from any thread: `AIModelRegistry` does so from SwiftUI bodies,
/// the coordinator and tests.
final class ModelCatalogStore: @unchecked Sendable {
    static let shared = ModelCatalogStore()
    static let defaultsKey = "ai.modelCatalog.v1"
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    private struct Entry: Codable {
        struct Row: Codable {
            var id: String
            var displayName: String
        }
        var fetchedAt: Date
        var rows: [Row]
    }

    private let defaults: UserDefaults
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry]

    init(
        defaults: UserDefaults = .standard,
        ttl: TimeInterval = ModelCatalogStore.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.ttl = ttl
        self.now = now
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? Self.decoder.decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Nil when nothing usable is saved for this vendor.
    func models(for vendor: AIVendor) -> [AIModel]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[vendor.rawValue], !entry.rows.isEmpty else { return nil }
        return entry.rows.map {
            AIModel(id: $0.id, vendor: vendor, displayName: $0.displayName, tagline: AIModelRegistry.staticTagline(for: $0.id))
        }
    }

    func fetchedAt(_ vendor: AIVendor) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return entries[vendor.rawValue]?.fetchedAt
    }

    func isStale(_ vendor: AIVendor) -> Bool {
        guard let fetched = fetchedAt(vendor) else { return true }
        let age = now().timeIntervalSince(fetched)
        return age < 0 || age >= ttl
    }

    func save(_ models: [AIModel], for vendor: AIVendor) {
        lock.lock()
        defer { lock.unlock() }
        entries[vendor.rawValue] = Entry(
            fetchedAt: now(),
            rows: models.map { Entry.Row(id: $0.id, displayName: $0.displayName) }
        )
        if let data = try? Self.encoder.encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What the Settings screen and overlay watch: refreshes the saved lists and tells the UI
/// when one changed. Any failure leaves the previous list (or the built-in one) in place.
@MainActor
final class AIModelCatalog: ObservableObject {
    static let shared = AIModelCatalog()

    @Published private(set) var revision = 0
    @Published private(set) var refreshing: Set<AIVendor> = []
    @Published private(set) var lastError: [AIVendor: String] = [:]

    private let store: ModelCatalogStore
    private let fetcher: ModelListFetcher

    init(store: ModelCatalogStore = .shared, fetcher: ModelListFetcher = ModelListFetcher()) {
        self.store = store
        self.fetcher = fetcher
    }

    /// Fetches the vendor's list. Without `force`, a list younger than the TTL is left alone.
    func refresh(_ vendor: AIVendor, apiKey: String?, force: Bool) async {
        guard let apiKey, !apiKey.isEmpty, !refreshing.contains(vendor) else { return }
        guard force || store.isStale(vendor) else { return }
        refreshing.insert(vendor)
        defer { refreshing.remove(vendor) }
        do {
            let models = try await fetcher.fetch(vendor: vendor, apiKey: apiKey)
            store.save(models, for: vendor)
            lastError[vendor] = nil
            revision += 1
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError[vendor] = reason
            wpWarn("[Models] Couldn't load the \(vendor.displayName) model list: \(reason). Using the saved or built-in list.")
        }
    }

    func refreshIfStale(keys: [AIVendor: String?]) async {
        for (vendor, key) in keys {
            await refresh(vendor, apiKey: key, force: false)
        }
    }

    func lastUpdated(_ vendor: AIVendor) -> Date? {
        store.fetchedAt(vendor)
    }
}
