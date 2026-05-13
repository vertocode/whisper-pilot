import AVFoundation
import Foundation
import Speech
@testable import WhisperPilot

/// Minimal expect/suite harness. Returns 0 on success, 1 on failure.
/// Replace with swift-testing or XCTest once a full Xcode toolchain is available.
@main
struct SmokeTestRunner {
    static let stats = TestStats()

    static func main() async {
        await runQuestionDetectorSuite()
        await runTopicExtractorSuite()
        await runConversationContextSuite()
        await runPromptBuilderSuite()
        await runTriggerEngineSuite()
        await runSpeechRecognitionIntegrationSuite()

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

    // MARK: - Harness

    actor TestStats {
        private(set) var passed = 0
        private(set) var failures: [(name: String, message: String)] = []

        func recordPass() { passed += 1 }
        func recordFail(_ name: String, _ message: String) { failures.append((name, message)) }
        func snapshot() -> (passed: Int, failures: [(name: String, message: String)]) {
            (passed, failures)
        }
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) async {
        if condition {
            await stats.recordPass()
        } else {
            let location = "\(file):\(line)"
            let msg = message()
            await stats.recordFail(location, msg)
            FileHandle.standardError.write(Data("  ✘ \(location) \(msg)\n".utf8))
        }
    }

    static func suite(_ name: String, _ body: () async -> Void) async {
        print("• \(name)")
        await body()
    }

    // MARK: - Builders

    static func systemSegment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: text, isFinal: true, channel: .system, startedAt: Date(), updatedAt: Date())
    }

    static func micSegment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: text, isFinal: true, channel: .microphone, startedAt: Date(), updatedAt: Date())
    }

    static func snapshotFor(lines: [String] = [], topics: [String] = []) -> ConversationSnapshot {
        ConversationSnapshot(recentLines: lines, topics: topics, entities: [])
    }

    /// Race the engine's event stream against a timeout. Returns the first event or nil on timeout.
    static func collectFirstEvent(from engine: TriggerEngine, within seconds: TimeInterval) async -> TriggerEvent? {
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

    // MARK: - Suites

    static func runQuestionDetectorSuite() async {
        await suite("QuestionDetector") {
            let detector = QuestionDetector()

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

            // Regression: filler-prefixed questions used to score below threshold because
            // the interrogative starter ("why") was masked by the "okay, so" preamble.
            await expect(
                detector.score(systemSegment("Okay, so why did you choose that particular major and at that particular school?")) >= 0.6,
                "filler-prefixed question must still clear threshold"
            )
            await expect(
                detector.score(systemSegment("Yeah but how come you didn't ship the migration last week?")) >= 0.6,
                "yeah/but-prefixed question must still clear threshold"
            )
        }
    }

    static func runTopicExtractorSuite() async {
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

    static func runConversationContextSuite() async {
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

    static func runPromptBuilderSuite() async {
        await suite("PromptBuilder") {
            let p1 = PromptBuilder.build(context: snapshotFor(), history: [], question: "What's your opinion on modular monoliths?", style: .strategic)
            await expect(p1.systemInstruction.contains("strategic"), "style name appears in system instruction")

            let q = "How would you approach this migration?"
            let p2 = PromptBuilder.build(context: snapshotFor(), history: [], question: q, style: .concise)
            await expect(p2.question == q, "question is carried through")

            let lines = (0..<50).map { "Other: line \($0)" }
            let p3 = PromptBuilder.build(context: snapshotFor(lines: lines), history: [], question: "?", style: .concise)
            await expect(p3.context.contains("line 49"), "most recent line preserved")
            await expect(!p3.context.contains("line 0\n"), "earliest line trimmed")

            let p4 = PromptBuilder.build(context: snapshotFor(topics: ["postgres", "scaling"]), history: [], question: "What about sharding?", style: .detailed)
            await expect(p4.context.contains("postgres") && p4.context.contains("scaling"), "topics listed when present")
        }
    }

    /// End-to-end integration test: synthesize a known sentence via `AVSpeechSynthesizer`,
    /// feed the resulting audio buffers (converted to our canonical format) directly into
    /// `AppleSpeechTranscriber`, and verify a non-empty transcript comes back. Skipped if
    /// the toolchain doesn't have Speech Recognition authorized — that's a TCC environment
    /// issue, not a code bug, and we report it as such.
    static func runSpeechRecognitionIntegrationSuite() async {
        await suite("SpeechRecognition (integration)") {
            let auth = SFSpeechRecognizer.authorizationStatus()
            guard auth == .authorized else {
                print("  ⓘ Speech recognition not authorized on this machine (status=\(auth.rawValue)). Skipping integration test.")
                return
            }

            let transcriber = AppleSpeechTranscriber(locale: Locale(identifier: "en-US"))
            do {
                try await transcriber.start()
            } catch {
                await expect(false, "transcriber.start() threw: \(error.localizedDescription)")
                return
            }
            defer { transcriber.stop() }

            // Subscribe to transcripts in the background; capture text into a shared buffer.
            actor TranscriptCollector {
                var combined = ""
                func append(_ text: String) { combined = text } // last-wins (partial overwrites)
                func snapshot() -> String { combined }
            }
            let collector = TranscriptCollector()
            let collectorTask = Task {
                for await update in transcriber.transcripts {
                    await collector.append(update.text)
                    if update.isFinal { return }
                }
            }

            // Synthesize "Hello world this is a test of speech recognition"
            let synth = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: "Hello world. This is a test of speech recognition.")
            utterance.rate = 0.5
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

            let canonical = CanonicalAudioFormat.make()
            let synthesisFinished = Task<Void, Never> {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var finished = false
                    var converter: AVAudioConverter?
                    var sourceFormat: AVAudioFormat?
                    synth.write(utterance) { buffer in
                        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                            // synthesizer signals end-of-utterance with an empty buffer
                            if !finished {
                                finished = true
                                continuation.resume()
                            }
                            return
                        }
                        if sourceFormat?.isEqual(pcm.format) != true {
                            sourceFormat = pcm.format
                            converter = AVAudioConverter(from: pcm.format, to: canonical)
                        }
                        guard let converter else { return }
                        let outputCapacity = AVAudioFrameCount(Double(pcm.frameLength) * canonical.sampleRate / pcm.format.sampleRate) + 1024
                        guard let out = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outputCapacity) else { return }
                        var error: NSError?
                        var consumed = false
                        converter.convert(to: out, error: &error) { _, status in
                            if consumed { status.pointee = .endOfStream; return nil }
                            consumed = true
                            status.pointee = .haveData
                            return pcm
                        }
                        if error == nil, out.frameLength > 0 {
                            transcriber.feed(out, channel: .system)
                        }
                    }
                }
            }
            _ = await synthesisFinished.value

            // Give the recognizer a couple of seconds to flush trailing partial → final.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            collectorTask.cancel()

            let final = await collector.snapshot()
            print("  ⓘ Recognized: \"\(final)\"")
            let lower = final.lowercased()
            await expect(!final.isEmpty, "transcriber produced at least one transcript update for synthesized speech")
            await expect(lower.contains("hello") || lower.contains("test") || lower.contains("speech") || lower.contains("recognition"),
                         "recognized text contains at least one of the synthesized keywords (got: \"\(final)\")")
        }
    }

    static func runTriggerEngineSuite() async {
        await suite("TriggerEngine") {
            do {
                let engine = TriggerEngine()
                await engine.consider(segment: systemSegment("How would you scale this?"))
                await engine.absorb(.speechEnded(channel: .system, at: Date().addingTimeInterval(-1.0), duration: 2.0, silenceLeading: 0))
                let event = await collectFirstEvent(from: engine, within: 0.5)
                await expect(event != nil, "fires when question followed by pause")
                await expect(event?.text == "How would you scale this?", "carries question text")
            }

            do {
                let engine = TriggerEngine()
                await engine.consider(segment: systemSegment("How would you scale this?"))
                let event = await collectFirstEvent(from: engine, within: 0.4)
                await expect(event == nil, "no fire without speech-ended event")
            }

            do {
                let engine = TriggerEngine()
                await engine.consider(segment: systemSegment("yeah okay sure right"))
                await engine.absorb(.speechEnded(channel: .system, at: Date().addingTimeInterval(-1), duration: 1, silenceLeading: 0))
                let event = await collectFirstEvent(from: engine, within: 0.4)
                await expect(event == nil, "low-score segments don't fire")
            }
        }
    }
}
