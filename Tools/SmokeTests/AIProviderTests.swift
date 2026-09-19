import Foundation
@testable import WhisperPilot

/// Serves canned HTTP responses so the providers' SSE parsing can be tested with no network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var requestCount = 0
    private static let lock = NSLock()

    /// Each request consumes the next reply; the last one repeats.
    static func install(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        requestCount = 0
    }

    static var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            let index = min(Self.requestCount, Self.replies.count - 1)
            Self.requestCount += 1
            return Self.replies[index]
        }()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"].merging(reply.headers) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension SmokeTestRunner {
    struct StreamOutcome {
        var deltas: [String] = []
        var finish: AIFinishReason?
        var error: Error?
    }

    static func collect(_ provider: AIProvider) async -> StreamOutcome {
        var outcome = StreamOutcome()
        let prompt = Prompt(systemInstruction: "s", context: "c", question: "q", style: .concise)
        do {
            for try await event in provider.streamCompletion(prompt: prompt) {
                switch event {
                case .delta(let text): outcome.deltas.append(text)
                case .finish(let reason): outcome.finish = reason
                }
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    static func runAIProviderSuite() async {
        func gemini() -> GeminiProvider {
            GeminiProvider(apiKey: "test", model: "gemini-2.5-flash", session: StubURLProtocol.session())
        }
        func claude() -> AnthropicProvider {
            AnthropicProvider(apiKey: "test", model: "claude-sonnet-4-6", session: StubURLProtocol.session())
        }
        func sse(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

        await suite("Gemini stream parsing") {
            StubURLProtocol.install([.init(status: 200, body: sse(
                #"data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}"#, "",
                #"data: {"candidates":[{"content":{"parts":[{"text":"lo"}]},"finishReason":"STOP"}]}"#, ""
            ))])
            let ok = await collect(gemini())
            await expect(ok.deltas == ["Hel", "lo"], "text chunks arrive in order")
            await expect(ok.finish == .stop, "STOP maps to a clean finish")
            await expect(ok.error == nil, "clean stream does not throw")

            StubURLProtocol.install([.init(status: 200, body: sse(
                #"data: {"candidates":[{"content":{"parts":[{"text":"cut"}]},"finishReason":"MAX_TOKENS"}]}"#, ""
            ))])
            let capped = await collect(gemini())
            await expect(capped.finish == .maxTokens, "MAX_TOKENS is reported")

            StubURLProtocol.install([.init(status: 200, body: sse(
                #"data: {"candidates":[{"content":{"parts":[{"text":"partial"}]}}]}"#, ""
            ))])
            let noReason = await collect(gemini())
            await expect(noReason.finish == .other(nil), "stream with no finish reason is flagged")

            StubURLProtocol.install([.init(status: 200, body: sse(
                #"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#, ""
            ))])
            let blocked = await collect(gemini())
            if case GeminiError.promptBlocked(let reason)? = blocked.error {
                await expect(reason == "SAFETY", "blocked prompt reports the block reason")
            } else {
                await expect(false, "blocked prompt should throw promptBlocked, got \(String(describing: blocked.error))")
            }

            StubURLProtocol.install([.init(status: 200, body: sse("data: [1,2,3]", "", "data: [4]", ""))])
            let garbled = await collect(gemini())
            if case GeminiError.unexpectedFormat? = garbled.error {
                await expect(true, "undecodable chunks with no text -> unexpected format")
            } else {
                await expect(false, "expected unexpectedFormat, got \(String(describing: garbled.error))")
            }

            StubURLProtocol.install([.init(status: 200, body: sse(
                "data: [1]", "",
                #"data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#, ""
            ))])
            let mixed = await collect(gemini())
            await expect(mixed.error == nil && mixed.deltas == ["ok"], "one bad chunk among good ones is tolerated")

            let longBody = String(repeating: "x", count: 5000)
            StubURLProtocol.install([.init(status: 400, body: longBody)])
            let bad = await collect(gemini())
            await expect((bad.error?.localizedDescription.count ?? 9999) < 400, "HTTP 400 message does not dump the whole body")
        }

        await suite("Anthropic stream parsing") {
            StubURLProtocol.install([.init(status: 200, body: sse(
                "event: content_block_delta",
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#, "",
                "event: message_delta",
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, ""
            ))])
            let ok = await collect(claude())
            await expect(ok.deltas == ["Hi"] && ok.finish == .stop, "text delta and end_turn parse")

            StubURLProtocol.install([.init(status: 200, body: sse(
                "event: content_block_delta",
                #"data: {"delta":{"text":"a"}}"#, "",
                "event: error",
                #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, ""
            ))])
            let midStream = await collect(claude())
            if case AnthropicError.stream(let type, _)? = midStream.error {
                await expect(type == "overloaded_error", "mid-stream error event is thrown with its type")
            } else {
                await expect(false, "expected a stream error, got \(String(describing: midStream.error))")
            }

            StubURLProtocol.install([.init(status: 200, body: sse(
                "event: content_block_delta", "data: [1]", ""
            ))])
            let garbled = await collect(claude())
            if case AnthropicError.unexpectedFormat? = garbled.error {
                await expect(true, "undecodable events with no text -> unexpected format")
            } else {
                await expect(false, "expected unexpectedFormat, got \(String(describing: garbled.error))")
            }

            StubURLProtocol.install([.init(status: 200, body: sse(
                "event: message_delta",
                #"data: {"delta":{"stop_reason":"max_tokens"}}"#, ""
            ))])
            let empty = await collect(claude())
            await expect(empty.error == nil && empty.finish == .maxTokens, "empty reply with a valid stop reason is not an error")
        }

        await suite("AI retry") {
            let good = StubURLProtocol.Reply(status: 200, body: sse(
                #"data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#, ""
            ))
            let now = StubURLProtocol.Reply(status: 429, body: "slow down", headers: ["Retry-After": "0"])

            StubURLProtocol.install([now, good])
            let recovered = await collect(gemini())
            await expect(recovered.deltas == ["ok"] && recovered.error == nil, "429 with Retry-After: 0 is retried once and succeeds")
            await expect(StubURLProtocol.requests == 2, "exactly one retry was made")

            StubURLProtocol.install([now])
            let twice = await collect(gemini())
            await expect(twice.error != nil && twice.deltas.isEmpty, "a second failure surfaces")
            await expect(StubURLProtocol.requests == 2, "never more than one retry")

            StubURLProtocol.install([.init(status: 429, body: "x", headers: ["Retry-After": "120"]), good])
            let tooLong = await collect(gemini())
            await expect(tooLong.error != nil && StubURLProtocol.requests == 1, "a long Retry-After is not waited for")

            StubURLProtocol.install([.init(status: 404, body: "nope"), good])
            let notFound = await collect(gemini())
            await expect(notFound.error != nil && StubURLProtocol.requests == 1, "404 is not retried")

            StubURLProtocol.install([.init(status: 401, body: "bad key"), good])
            let unauthorized = await collect(gemini())
            await expect(unauthorized.error != nil && StubURLProtocol.requests == 1, "401 is not retried")

            let claudeGood = StubURLProtocol.Reply(status: 200, body: sse(
                "event: content_block_delta", #"data: {"delta":{"text":"hi"}}"#, "",
                "event: message_delta", #"data: {"delta":{"stop_reason":"end_turn"}}"#, ""
            ))
            StubURLProtocol.install([.init(status: 529, body: "overloaded", headers: ["Retry-After": "0"]), claudeGood])
            let claudeRecovered = await collect(claude())
            await expect(claudeRecovered.deltas == ["hi"] && StubURLProtocol.requests == 2, "Claude 529 is retried once and succeeds")

            let overloadedEvent = StubURLProtocol.Reply(status: 200, body: sse(
                "event: error", #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, ""
            ))
            StubURLProtocol.install([overloadedEvent, claudeGood])
            let eventRetried = await collect(claude())
            await expect(eventRetried.deltas == ["hi"], "overloaded error event before any text is retried")

            StubURLProtocol.install([.init(status: 200, body: sse(
                "event: content_block_delta", #"data: {"delta":{"text":"a"}}"#, "",
                "event: error", #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, ""
            )), claudeGood])
            let afterText = await collect(claude())
            await expect(afterText.error != nil && StubURLProtocol.requests == 1, "no retry once text has reached the user")

            await expect(AIRetryPolicy.delay(forStatus: 503, retryAfter: nil, jitter: 0) == 1, "5xx without Retry-After waits the base delay")
            await expect(AIRetryPolicy.delay(forStatus: 503, retryAfter: nil, jitter: 1) == 1.5, "jitter adds up to half a second")
            await expect(AIRetryPolicy.delay(forStatus: 200, retryAfter: nil, jitter: 0) == nil, "success is never retried")
            await expect(AIRetryPolicy.delay(forStatus: 400, retryAfter: nil, jitter: 0) == nil, "400 is never retried")
            await expect(AIRetryPolicy.delay(forStatus: 429, retryAfter: "3", jitter: 1) == 3, "Retry-After seconds are honored")
            await expect(
                AIRetryPolicy.delay(after: URLError(.networkConnectionLost), retryAfter: nil, jitter: 0) == 1,
                "dropped connection is retried"
            )
            await expect(
                AIRetryPolicy.delay(after: URLError(.notConnectedToInternet), retryAfter: nil, jitter: 0) == nil,
                "no internet is not retried"
            )
            await expect(AIRetryPolicy.delay(after: CancellationError(), retryAfter: nil, jitter: 0) == nil, "cancellation is not retried")
        }

        await suite("Repeated notes") {
            func note(_ text: String, role: ChatMessage.Role = .system) -> ChatMessage {
                ChatMessage(id: UUID(), role: role, origin: .system, text: text, timestamp: Date(), isStreaming: false, category: .ai, actionLabel: nil, actionKind: nil)
            }
            let error = "⚠️ Gemini rate limit hit"
            await expect(!RepeatedNote.isRepeat(error, in: []), "empty chat -> not a repeat")
            await expect(RepeatedNote.isRepeat(error, in: [note(error)]), "same note just shown -> repeat")
            await expect(!RepeatedNote.isRepeat(error, in: [note("other")]), "different note -> not a repeat")
            await expect(!RepeatedNote.isRepeat(error, in: [note(error, role: .assistant)]), "an assistant message with the same text is not a note")
            let buried = [note(error)] + (0..<6).map { note("filler \($0)") }
            await expect(!RepeatedNote.isRepeat(error, in: buried), "an old note far up the chat does not count")
        }

        await suite("AI error messages") {
            let known = Set(AIModelRegistry.all.map(\.id))
            let statuses = [400, 401, 403, 404, 429, 500, 503, 418]
            var mentioned = Set<String>()
            for status in statuses {
                let text = GeminiError.http(status: status, body: nil).errorDescription ?? ""
                let pattern = try! NSRegularExpression(pattern: "gemini-[a-z0-9.-]*[a-z0-9]")
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range, in: text) { mentioned.insert(String(text[range])) }
                }
            }
            await expect(!mentioned.isEmpty, "Gemini messages name at least one model")
            await expect(mentioned.isSubset(of: known), "every model named in Gemini messages exists in the registry: \(mentioned.subtracting(known))")

            await expect(AIErrorBody.summary(nil) == nil, "no body -> no detail")
            await expect(AIErrorBody.summary("  \n ") == nil, "blank body -> no detail")
            await expect(
                AIErrorBody.summary(#"{"error":{"message":"API key not valid"}}"#) == "API key not valid",
                "JSON error body -> its message"
            )
            await expect((AIErrorBody.summary(String(repeating: "y", count: 900))?.count ?? 0) <= 201, "long body is cut")
        }
    }
}
