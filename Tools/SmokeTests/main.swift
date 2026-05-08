import Foundation
@testable import WhisperPilot

// Minimal expect/suite harness. Returns 0 on success, 1 on failure.
// Replace with swift-testing or XCTest once Xcode is present.

actor TestStats {
    var passed = 0
    var failed: [(name: String, message: String)] = []

    func recordPass() { passed += 1 }
    func recordFail(_ name: String, _ message: String) { failed.append((name, message)) }
    func snapshot() -> (passed: Int, failures: [(name: String, message: String)]) {
        (passed, failed)
    }
}

let stats = TestStats()

func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) async {
    if condition {
        await stats.recordPass()
    } else {
        await stats.recordFail("\(file):\(line)", message())
        FileHandle.standardError.write(Data("  ✘ \(file):\(line) \(message())\n".utf8))
    }
}

func suite(_ name: String, _ body: () async -> Void) async {
    print("• \(name)")
    await body()
}

// MARK: - QuestionDetector

func runQuestionDetectorSuite() async {
    await suite("QuestionDetector") {
        let detector = QuestionDetector()
        func systemSegment(_ text: String) -> TranscriptSegment {
            TranscriptSegment(id: UUID(), text: text, isFinal: true, channel: .system, startedAt: Date(), updatedAt: Date())
        }
        func micSegment(_ text: String) -> TranscriptSegment {
            TranscriptSegment(id: UUID(), text: text, isFinal: true, channel: .microphone, startedAt: Date(), updatedAt: Date())
        }

        await expect(detector.score(micSegment("How would you design this system?")) == 0,
                     "microphone channel must score 0")

        await expect(detector.score(systemSegment("hi?")) == 0,
                     "very short utterance must score 0")

        await expect(detector.score(systemSegment("How would you scale this service?")) >= 0.6,
                     "interrogative+question-mark must clear threshold")

        await expect(detector.score(systemSegment("Can you walk us through your approach")) >= 0.6,
                     "modal lead must clear threshold even without ?")

        await expect(detector.score(systemSegment("yeah right okay sure that makes sense")) < 0.6,
                     "filler starts must be downweighted")

        await expect(detector.score(systemSegment("I wonder why?")) < 0.7,
                     "trailing ? alone shouldn't dominate")

        let long = String(repeating: "and then we did some stuff ", count: 5) + "what do you think?"
        await expect(detector.score(systemSegment(long)) < 0.7,
                     "very long utterances downweighted")

        let withYou = detector.score(systemSegment("How does this affect you in production?"))
        let withoutYou = detector.score(systemSegment("How does this affect production stability?"))
        await expect(withYou > withoutYou, "presence of 'you' raises score")
    }
}

// MARK: - TopicExtractor

func runTopicExtractorSuite() async {
    await suite("TopicExtractor") {
        let extractor = TopicExtractor()

        let r1 = extractor.extract(from: "We need to discuss database performance and replication strategy.")
        await expect(r1.topics.contains("database"), "topics include 'database'")
        await expect(r1.topics.contains("performance"), "topics include 'performance'")

        let r2 = extractor.extract(from: "The thing is people kind of talked about lots of stuff.")
        await expect(!r2.topics.contains("thing"), "stopword 'thing' filtered")
        await expect(!r2.topics.contains("people"), "stopword 'people' filtered")
        await expect(!r2.topics.contains("stuff"), "stopword 'stuff' filtered")

        let r3 = extractor.extract(from: "Database. database. DATABASE.")
        let occ = r3.topics.filter { $0.lowercased() == "database" }.count
        await expect(occ <= 1, "case-insensitive dedupe")
    }
}

// MARK: - ConversationContext

func runConversationContextSuite() async {
    await suite("ConversationContext") {
        let context = ConversationContext()
        await context.absorb(.init(id: UUID(), text: "How does the cache invalidation work?", isFinal: true, channel: .system, timestamp: Date()))
        await context.absorb(.init(id: UUID(), text: "We invalidate on write through.", isFinal: true, channel: .microphone, timestamp: Date()))

        let snap1 = await context.snapshot()
        await expect(snap1.recentLines.count == 2, "two finalized lines absorbed")
        await expect(snap1.recentLines[0].hasPrefix("Other:"), "system channel attributed to 'Other'")
        await expect(snap1.recentLines[1].hasPrefix("Me:"), "microphone channel attributed to 'Me'")

        let context2 = ConversationContext()
        await context2.absorb(.init(id: UUID(), text: "How does the…", isFinal: false, channel: .system, timestamp: Date()))
        let snap2 = await context2.snapshot()
        await expect(snap2.recentLines.isEmpty, "partial segments not absorbed")

        let context3 = ConversationContext()
        await context3.absorb(.init(id: UUID(), text: "Tell me about your database architecture.", isFinal: true, channel: .system, timestamp: Date()))
        await context3.absorb(.init(id: UUID(), text: "We use Postgres for transactional storage.", isFinal: true, channel: .microphone, timestamp: Date()))
        let snap3 = await context3.snapshot()
        await expect(snap3.topics.contains { $0.hasPrefix("database") }, "topics accumulate across turns")

        let context4 = ConversationContext()
        await context4.absorb(.init(id: UUID(), text: "Tell me about scaling.", isFinal: true, channel: .system, timestamp: Date()))
        await context4.reset()
        let snap4 = await context4.snapshot()
        await expect(snap4.recentLines.isEmpty && snap4.topics.isEmpty, "reset clears state")
    }
}

// MARK: - PromptBuilder

func runPromptBuilderSuite() async {
    await suite("PromptBuilder") {
        func snapshot(lines: [String] = [], topics: [String] = []) -> ConversationSnapshot {
            ConversationSnapshot(recentLines: lines, topics: topics, entities: [])
        }

        let p1 = PromptBuilder.build(context: snapshot(), question: "What's your opinion on modular monoliths?", style: .strategic)
        await expect(p1.systemInstruction.contains("strategic"), "style name appears in system instruction")

        let q = "How would you approach this migration?"
        let p2 = PromptBuilder.build(context: snapshot(), question: q, style: .concise)
        await expect(p2.question == q, "question is carried through")

        let lines = (0..<50).map { "Other: line \($0)" }
        let p3 = PromptBuilder.build(context: snapshot(lines: lines), question: "?", style: .concise)
        await expect(p3.context.contains("line 49"), "most recent line preserved")
        await expect(!p3.context.contains("line 0\n"), "earliest line trimmed")

        let p4 = PromptBuilder.build(context: snapshot(topics: ["postgres", "scaling"]), question: "What about sharding?", style: .detailed)
        await expect(p4.context.contains("postgres") && p4.context.contains("scaling"), "topics listed when present")
    }
}

// MARK: - TriggerEngine

func collectFirstEvent(from engine: TriggerEngine, within seconds: TimeInterval) async -> TriggerEvent? {
    await withTaskGroup(of: TriggerEvent?.self) { group in
        group.addTask {
            for await event in engine.events { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

func runTriggerEngineSuite() async {
    await suite("TriggerEngine") {
        func systemSegment(_ text: String) -> TranscriptSegment {
            TranscriptSegment(id: UUID(), text: text, isFinal: true, channel: .system, startedAt: Date(), updatedAt: Date())
        }

        // 1. Fires when question followed by pause
        do {
            let engine = TriggerEngine()
            let segment = systemSegment("How would you scale this?")
            await engine.consider(segment: segment)
            await engine.absorb(.speechEnded(channel: .system, at: Date().addingTimeInterval(-1.0), duration: 2.0, silenceLeading: 0))
            let event = await collectFirstEvent(from: engine, within: 0.5)
            await expect(event != nil, "fires when question followed by pause")
            await expect(event?.text == "How would you scale this?", "carries question text")
        }

        // 2. Doesn't fire without observed pause
        do {
            let engine = TriggerEngine()
            await engine.consider(segment: systemSegment("How would you scale this?"))
            let event = await collectFirstEvent(from: engine, within: 0.4)
            await expect(event == nil, "no fire without speech-ended event")
        }

        // 3. Ignores low-score segments
        do {
            let engine = TriggerEngine()
            await engine.consider(segment: systemSegment("yeah okay sure right"))
            await engine.absorb(.speechEnded(channel: .system, at: Date().addingTimeInterval(-1), duration: 1, silenceLeading: 0))
            let event = await collectFirstEvent(from: engine, within: 0.4)
            await expect(event == nil, "low-score segments don't fire")
        }
    }
}

// MARK: - Run all

@main
struct SmokeTestRunner {
    static func main() async {
        await runQuestionDetectorSuite()
        await runTopicExtractorSuite()
        await runConversationContextSuite()
        await runPromptBuilderSuite()
        await runTriggerEngineSuite()

        let snapshot = await stats.snapshot()
        let total = snapshot.passed + snapshot.failures.count
        if snapshot.failures.isEmpty {
            print("\n✓ \(snapshot.passed)/\(total) assertions passed")
            exit(0)
        } else {
            print("\n✘ \(snapshot.failures.count) failure(s) of \(total):")
            for f in snapshot.failures {
                print("  - \(f.name): \(f.message)")
            }
            exit(1)
        }
    }
}
