import Foundation
@testable import WhisperPilot

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

extension SmokeTestRunner {
    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "model-catalog-\(UUID().uuidString)")!
    }

    static func runModelCatalogSuite() async {
        await suite("Model lists: parsing") {
            let anthropic = Data("""
            {"data":[
              {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-01-01T00:00:00Z"},
              {"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-01-01T00:00:00Z"},
              {"type":"model","id":"not-a-claude","display_name":"Odd"}
            ],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-haiku-5-5"}
            """.utf8)
            let page = try? ModelListParser.parseAnthropic(anthropic)
            await expect(page?.models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5"], "Anthropic ids parsed, non-Claude dropped")
            await expect(page?.models.first?.displayName == "Claude Opus 5.5", "Anthropic display name used")
            await expect(page?.models.allSatisfy { $0.vendor == .anthropic } == true, "Anthropic vendor set")
            await expect(page?.next == "claude-haiku-5-5", "has_more gives the last id as the next cursor")
            await expect(page?.models.first?.tagline == "highest quality, slower", "known models keep their tagline")

            let last = try? ModelListParser.parseAnthropic(Data(#"{"data":[],"has_more":false,"last_id":"x"}"#.utf8))
            await expect(last?.next == nil && last?.models.isEmpty == true, "last page has no cursor")
            let noName = try? ModelListParser.parseAnthropic(Data(#"{"data":[{"id":"claude-x-1"}]}"#.utf8))
            await expect(noName?.models.first?.displayName == "claude-x-1", "missing display name falls back to the id")
            await expect((try? ModelListParser.parseAnthropic(Data("nope".utf8))) == nil, "garbage throws")

            let gemini = Data("""
            {"models":[
              {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
              {"name":"models/gemini-embedding-001","displayName":"Embedding","supportedGenerationMethods":["embedContent"]},
              {"name":"models/gemini-2.5-flash-preview-tts","displayName":"TTS","supportedGenerationMethods":["generateContent"]},
              {"name":"models/gemma-3-27b","displayName":"Gemma","supportedGenerationMethods":["generateContent"]},
              {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]}
            ],"nextPageToken":"abc"}
            """.utf8)
            let g = try? ModelListParser.parseGemini(gemini)
            await expect(g?.models.map(\.id) == ["gemini-2.5-flash", "gemini-2.5-pro"],
                         "Gemini keeps text models only and strips the models/ prefix")
            await expect(g?.models.last?.displayName == "gemini-2.5-pro", "Gemini missing displayName falls back to the id")
            await expect(g?.next == "abc", "Gemini page token is the cursor")
            let empty = try? ModelListParser.parseGemini(Data("{}".utf8))
            await expect(empty?.models.isEmpty == true && empty?.next == nil, "Gemini empty body parses to nothing")
        }

        await suite("Model lists: requests and pagination") {
            let a1 = ModelListFetcher.request(vendor: .anthropic, apiKey: "sk-test", cursor: nil)
            await expect(a1.url?.host == "api.anthropic.com" && a1.url?.path == "/v1/models", "Anthropic URL")
            await expect(a1.value(forHTTPHeaderField: "x-api-key") == "sk-test", "Anthropic key in x-api-key")
            await expect(a1.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version header")
            await expect(a1.url?.query?.contains("after_id") == false, "first page has no cursor")
            let a2 = ModelListFetcher.request(vendor: .anthropic, apiKey: "k", cursor: "claude-b")
            await expect(a2.url?.query?.contains("after_id=claude-b") == true, "next page sends after_id")
            let g1 = ModelListFetcher.request(vendor: .gemini, apiKey: "g-test", cursor: "tok")
            await expect(g1.value(forHTTPHeaderField: "x-goog-api-key") == "g-test", "Gemini key in header, not in the URL")
            await expect(g1.url?.absoluteString.contains("g-test") == false, "key is not in the URL")
            await expect(g1.url?.query?.contains("pageToken=tok") == true, "Gemini sends pageToken")

            let log = RequestLog()
            let pages: [String: String] = [
                "": #"{"data":[{"id":"claude-a-1","display_name":"A"},{"id":"claude-b-1","display_name":"B"}],"has_more":true,"last_id":"claude-b-1"}"#,
                "claude-b-1": #"{"data":[{"id":"claude-b-1","display_name":"B"},{"id":"claude-c-1","display_name":"C"}],"has_more":false,"last_id":"claude-c-1"}"#
            ]
            let fetcher = ModelListFetcher(transport: { request in
                log.add(request)
                let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "after_id" }?.value ?? ""
                return (Data((pages[cursor] ?? "{}").utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let models = try? await fetcher.fetch(vendor: .anthropic, apiKey: "k")
            await expect(models?.map(\.id) == ["claude-a-1", "claude-b-1", "claude-c-1"], "two pages are joined and duplicates dropped")
            await expect(log.all.count == 2, "exactly two requests were made")

            let endless = ModelListFetcher(transport: { request in
                (Data(#"{"data":[{"id":"claude-z-1"}],"has_more":true,"last_id":"claude-z-1"}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let capped = try? await endless.fetch(vendor: .anthropic, apiKey: "k")
            await expect(capped?.count == 1, "a server that always says has_more still ends")

            func failing(_ status: Int, body: String = "{}") -> ModelListFetcher {
                ModelListFetcher(transport: { request in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                })
            }
            do {
                _ = try await failing(401).fetch(vendor: .anthropic, apiKey: "bad")
                await expect(false, "401 throws")
            } catch {
                await expect((error as? ModelListError) == .http(401), "401 is reported as an HTTP error")
            }
            do {
                _ = try await failing(200, body: #"{"data":[]}"#).fetch(vendor: .anthropic, apiKey: "k")
                await expect(false, "an empty list throws")
            } catch {
                await expect((error as? ModelListError) == .empty, "an empty list is an error, not a new empty picker")
            }
            do {
                _ = try await failing(200, body: "<html>").fetch(vendor: .gemini, apiKey: "k")
                await expect(false, "garbage throws")
            } catch {
                await expect((error as? ModelListError) == .badResponse, "unreadable body is reported")
            }
        }

        await suite("Model lists: cache, refresh and fallback") {
            let defaults = freshDefaults()
            let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
            let store = ModelCatalogStore(defaults: defaults, ttl: 3_600, now: { clock.now })

            await expect(store.models(for: .anthropic) == nil, "nothing cached at first")
            await expect(store.isStale(.anthropic), "nothing cached counts as stale")
            await expect(AIModelRegistry.models(for: .anthropic, catalog: store) == AIModelRegistry.staticModels(for: .anthropic),
                         "no fetched list → the built-in list")

            let fetched = [AIModel(id: "claude-new-9", vendor: .anthropic, displayName: "Claude New 9", tagline: nil)]
            store.save(fetched, for: .anthropic)
            await expect(AIModelRegistry.models(for: .anthropic, catalog: store).map(\.id) == ["claude-new-9"], "fetched list replaces the built-in one")
            await expect(AIModelRegistry.models(for: .gemini, catalog: store) == AIModelRegistry.staticModels(for: .gemini),
                         "other vendors keep their built-in list")
            await expect(AIModelRegistry.model(for: "claude-new-9", catalog: store)?.displayName == "Claude New 9", "fetched ids resolve")
            await expect(AIModelRegistry.model(for: "claude-sonnet-5-5", catalog: store) != nil, "built-in ids still resolve")
            await expect(AIModelRegistry.model(for: "claude-sonnet-4-6", catalog: store) != nil, "retired ids still resolve for saved selections")
            await expect(AIModelRegistry.model(for: "nonsense", catalog: store) == nil, "unknown ids do not")
            let builtInGemini = AIModelRegistry.staticModels(for: .gemini).map(\.id)
            await expect(!builtInGemini.contains { $0.hasPrefix("gemini-2.0") }, "built-in Gemini list has no retired 2.0 ids")
            await expect(AIModelRegistry.model(for: "gemini-2.0-flash", catalog: store) != nil, "retired Gemini ids still resolve for saved selections")

            await expect(!store.isStale(.anthropic), "fresh right after saving")
            clock.now = clock.now.addingTimeInterval(3_599)
            await expect(!store.isStale(.anthropic), "still fresh just before the TTL")
            clock.now = clock.now.addingTimeInterval(2)
            await expect(store.isStale(.anthropic), "stale after the TTL")

            let reopened = ModelCatalogStore(defaults: defaults, ttl: 3_600, now: { clock.now })
            await expect(reopened.models(for: .anthropic)?.map(\.id) == ["claude-new-9"], "the list survives a restart")
            await expect(reopened.fetchedAt(.anthropic) != nil, "so does its date")

            let corrupt = freshDefaults()
            corrupt.set(Data("garbage".utf8), forKey: ModelCatalogStore.defaultsKey)
            await expect(ModelCatalogStore(defaults: corrupt).models(for: .gemini) == nil, "a damaged cache is ignored")

            // Built-in lists are the current ones.
            let builtIn = AIModelRegistry.staticModels(for: .anthropic).map(\.id)
            await expect(builtIn == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"], "built-in Claude list is current")
            await expect(AIModelRegistry.defaultModel(availableVendors: [.anthropic]).id == "claude-haiku-5-5", "default Claude model comes from the built-in list")

            // Catalog: refresh fills the cache, a failure keeps what was there.
            let calls = RequestLog()
            let okFetcher = ModelListFetcher(transport: { request in
                calls.add(request)
                return (Data(#"{"data":[{"id":"claude-fresh-1","display_name":"Fresh"}],"has_more":false}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let badFetcher = ModelListFetcher(transport: { request in
                calls.add(request)
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            })
            let freshStore = ModelCatalogStore(defaults: freshDefaults(), ttl: 3_600, now: { clock.now })
            let catalog = await AIModelCatalog(store: freshStore, fetcher: okFetcher)
            await catalog.refresh(.anthropic, apiKey: nil, force: true)
            await expect(calls.all.isEmpty, "no key → no request")
            await catalog.refresh(.anthropic, apiKey: "k", force: false)
            await expect(freshStore.models(for: .anthropic)?.map(\.id) == ["claude-fresh-1"], "refresh stores the fetched list")
            await expect(await catalog.revision == 1, "the UI is told the list changed")
            await catalog.refresh(.anthropic, apiKey: "k", force: false)
            await expect(calls.all.count == 1, "a fresh list is not fetched again without force")
            await catalog.refresh(.anthropic, apiKey: "k", force: true)
            await expect(calls.all.count == 2, "force fetches even a fresh list")

            let failing = await AIModelCatalog(store: freshStore, fetcher: badFetcher)
            await failing.refresh(.anthropic, apiKey: "k", force: true)
            await expect(freshStore.models(for: .anthropic)?.map(\.id) == ["claude-fresh-1"], "a failed refresh keeps the previous list")
            await expect(await failing.lastError[.anthropic] != nil, "a failed refresh reports why")
            await expect(await failing.refreshing.isEmpty, "refreshing flag is cleared after a failure")

            let neverFetched = ModelCatalogStore(defaults: freshDefaults())
            let offline = await AIModelCatalog(store: neverFetched, fetcher: badFetcher)
            await offline.refresh(.gemini, apiKey: "k", force: true)
            await expect(AIModelRegistry.models(for: .gemini, catalog: neverFetched) == AIModelRegistry.staticModels(for: .gemini),
                         "failure with nothing cached falls back to the built-in list")
        }
    }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
