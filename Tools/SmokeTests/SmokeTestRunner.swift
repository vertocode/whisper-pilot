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
        await runUpdateCheckerSuite()
        await runStreamingAudioConverterSuite()
        await runSystemAudioGainSuite()
        await runTranscriptBufferSuite()
        await runReplayOverlapTrimmerSuite()
        await runTranscriptStreamSegmenterSuite()
        await runTranscriptDedupSuite()
        await runTranscriptRobustnessSuite()
        await runResourceGovernorSuite()
        await runSessionStoreParsingSuite()
        await runSpeechRecognitionIntegrationSuite()
        await runParakeetIntegrationSuite()

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

            // QuestionDetector is now channel-agnostic — the same text scores
            // the same regardless of which side spoke it. Channel-specific
            // gating lives in SettingsStore (autoDetectQuestionsFromMe /
            // autoDetectQuestionsFromOther) and is enforced by AppCoordinator
            // before/after the engine fires.
            await expect(
                detector.score(micSegment("How would you design this system?"))
                    == detector.score(systemSegment("How would you design this system?")),
                "same text scores identically on mic vs system channels"
            )

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

            // Containment-duplicate finals under different ids (synthetic
            // pre-flush + the recognizer's own final) merge into one line —
            // mirrors TranscriptBuffer so the AI sees what the user sees.
            let context5 = ConversationContext()
            await context5.absorb(.init(id: UUID(), text: "we ship on friday", isFinal: true, channel: .microphone, timestamp: Date()))
            await context5.absorb(.init(id: UUID(), text: "We ship on Friday.", isFinal: true, channel: .microphone, timestamp: Date()))
            let snap5 = await context5.snapshot()
            await expect(snap5.recentLines.count == 1, "duplicate finals merged into one context line (got \(snap5.recentLines.count))")
            await expect(snap5.recentLines.first == "Me: We ship on Friday.", "merged line keeps the more complete text (got \(snap5.recentLines.first ?? "nil"))")
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

            // Summary prompt: directive must mention summarizing the meeting, must
            // include the transcript context, and must not fabricate. Use one
            // real-looking line so the context-block assertion has something to
            // match against.
            let summaryCtx = snapshotFor(lines: ["Other: We decided to migrate to Postgres next sprint."])
            let summary = PromptBuilder.buildSummary(context: summaryCtx, history: [])
            await expect(summary.systemInstruction.localizedCaseInsensitiveContains("summariz"),
                         "summary system instruction says to summarize")
            await expect(summary.context.contains("Postgres next sprint"),
                         "summary carries the transcript context through")

            // Action items prompt: must mention action items AND must instruct
            // the model to use the "no items" sentence verbatim when empty —
            // otherwise the user gets vague hedging on quiet meetings.
            let actionsCtx = snapshotFor(lines: ["Me: I'll send the PR for review by Friday."])
            let actions = PromptBuilder.buildActionItems(context: actionsCtx, history: [])
            await expect(actions.systemInstruction.localizedCaseInsensitiveContains("action item"),
                         "action-items system instruction names the task")
            await expect(actions.systemInstruction.contains("I analyzed the entire transcript but found no pending action items."),
                         "action-items prompt pins the exact empty-state sentence")
            await expect(actions.context.contains("send the PR for review"),
                         "action-items carries the transcript context through")
        }
    }

    /// Pins the gain-and-soft-limit contract that `SystemAudioCapture` applies to every
    /// system-audio buffer (both the SCK and Process Tap paths). If someone changes the
    /// constant, removes the limiter, or breaks the multiply, this suite fails before a
    /// real meeting ever runs.
    static func runSystemAudioGainSuite() async {
        await suite("SystemAudioCapture gain") {
            await expect(SystemAudioCapture.systemAudioGain == 5.0,
                         "systemAudioGain constant is 5.0 (got \(SystemAudioCapture.systemAudioGain))")

            // Float32 mono buffer matching the canonical format the SCK path produces.
            let format = CanonicalAudioFormat.make()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6) else {
                await expect(false, "couldn't allocate test PCM buffer")
                return
            }
            buffer.frameLength = 6
            guard let data = buffer.floatChannelData else {
                await expect(false, "buffer has no floatChannelData (format isn't Float32?)")
                return
            }
            // Mix of values: quiet samples that 5× stay below the knee (must pass
            // through linearly), zero, one just past the knee (must compress
            // smoothly, NOT hard-clip), and loud positives/negatives whose 5×
            // magnitude drives the tanh segment essentially to ±1 — but never past.
            let inputs: [Float] = [0.05, -0.1, 0.0, 0.18, 0.5, -0.7]
            let expected: [Float] = [
                0.25,
                -0.5,
                0.0,
                SystemAudioCapture.softLimit(0.9),
                SystemAudioCapture.softLimit(2.5),
                SystemAudioCapture.softLimit(-3.5),
            ]
            for i in 0..<6 { data.pointee[i] = inputs[i] }

            SystemAudioCapture.applyGainInPlace(buffer, gain: SystemAudioCapture.systemAudioGain)

            for i in 0..<6 {
                let got = data.pointee[i]
                let exp = expected[i]
                await expect(abs(got - exp) < 1e-6,
                             "sample[\(i)] input=\(inputs[i]) expected=\(exp) got=\(got)")
            }

            // Soft-limit shape: linear below the knee, monotonic, bounded by ±1,
            // and strictly below the hard-clip value just past the knee (i.e. it
            // actually is soft).
            await expect(SystemAudioCapture.softLimit(0.8) == 0.8, "knee sample passes through untouched")
            await expect(SystemAudioCapture.softLimit(0.9) < 0.9, "post-knee sample is compressed below linear")
            await expect(SystemAudioCapture.softLimit(0.9) > 0.8, "post-knee sample stays above the knee")
            await expect(SystemAudioCapture.softLimit(100.0) <= 1.0, "extreme sample never exceeds +1")
            await expect(SystemAudioCapture.softLimit(-100.0) >= -1.0, "extreme sample never exceeds -1")

            // Sanity: applying gain to an empty buffer is a no-op, not a crash.
            guard let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
                await expect(false, "couldn't allocate empty buffer")
                return
            }
            empty.frameLength = 0
            SystemAudioCapture.applyGainInPlace(empty, gain: 5.0)
            await expect(empty.frameLength == 0, "empty buffer remains empty after applyGainInPlace")
        }
    }

    /// Pins the live-caption display invariants of `TranscriptBuffer`: append-only
    /// finals, one volatile row per channel, volatile consumed by the next final on
    /// its channel regardless of ids, and containment-merging of near-duplicate
    /// consecutive finals. These invariants are what prevent the "one phrase shows
    /// as many lines" / "gray+white duplicate rows" transcript bugs.
    static func runTranscriptBufferSuite() async {
        await suite("TranscriptBuffer") {
            func update(_ text: String, final: Bool, channel: AudioChannel = .system,
                        id: UUID = UUID(), at: Date = Date()) -> TranscriptUpdate {
                TranscriptUpdate(id: id, text: text, isFinal: final, channel: channel, timestamp: at)
            }

            // 1. Volatile refinements replace in place — never extra rows.
            do {
                let buffer = TranscriptBuffer()
                let id = UUID()
                await buffer.apply(update("hello", final: false, id: id))
                await buffer.apply(update("hello world", final: false, id: id))
                await buffer.apply(update("hello world how are", final: false, id: UUID()))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1, "volatile refinements collapse to 1 row (got \(snap.count))")
                await expect(snap.first?.text == "hello world how are", "volatile shows latest hypothesis")
                await expect(snap.first?.isFinal == false, "row is still volatile")
            }

            // 2. A final consumes the channel's volatile row even under a different id.
            do {
                let buffer = TranscriptBuffer()
                await buffer.apply(update("hello world", final: false, id: UUID()))
                await buffer.apply(update("Hello, world.", final: true, id: UUID()))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1, "final consumed the volatile row (got \(snap.count) rows)")
                await expect(snap.first?.isFinal == true, "row got committed")
                await expect(snap.first?.text == "Hello, world.", "final text wins")
            }

            // 3. Synthetic final then natural final (different ids, same words modulo
            //    punctuation) merge into one committed row.
            do {
                let buffer = TranscriptBuffer()
                await buffer.apply(update("we ship on friday", final: true, id: UUID()))
                await buffer.apply(update("We ship on Friday.", final: true, id: UUID()))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1, "containment-duplicate finals merged (got \(snap.count))")
            }

            // 4. A growing final under the SAME id updates in place.
            do {
                let buffer = TranscriptBuffer()
                let id = UUID()
                await buffer.apply(update("first half", final: true, id: id))
                await buffer.apply(update("first half and second half", final: true, id: id))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1, "same-id finals stay one row (got \(snap.count))")
                await expect(snap.first?.text == "first half and second half", "same-id final grew in place")
            }

            // 5. Distinct utterances separated by a real pause become distinct
            //    rows; channels stay independent.
            do {
                let buffer = TranscriptBuffer()
                let t0 = Date()
                await buffer.apply(update("question from the other side", final: true, channel: .system, at: t0))
                await buffer.apply(update("my own answer", final: true, channel: .microphone, at: t0.addingTimeInterval(3)))
                await buffer.apply(update("totally new topic", final: true, channel: .system, at: t0.addingTimeInterval(6)))
                let snap = await buffer.snapshot()
                await expect(snap.count == 3, "3 distinct pause-separated finals → 3 rows (got \(snap.count))")
            }

            // 6. A genuine repeat outside the merge window is preserved as its own row.
            do {
                let buffer = TranscriptBuffer()
                let earlier = Date(timeIntervalSinceNow: -60)
                await buffer.apply(update("yeah", final: true, at: earlier))
                await buffer.apply(update("yeah", final: true))
                let snap = await buffer.snapshot()
                await expect(snap.count == 2, "repeat said a minute later keeps its own row (got \(snap.count))")
            }

            // 7. An empty final never erases a live hypothesis — it commits it.
            do {
                let buffer = TranscriptBuffer()
                await buffer.apply(update("don't lose me", final: false))
                await buffer.apply(update("   ", final: true))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1, "empty final kept the hypothesis (got \(snap.count) rows)")
                await expect(snap.first?.isFinal == true, "hypothesis was promoted to final")
                await expect(snap.first?.text == "don't lose me", "promoted text is intact")
            }

            // 8. Late volatile for an already-committed segment id is ignored.
            do {
                let buffer = TranscriptBuffer()
                let id = UUID()
                await buffer.apply(update("committed", final: true, id: id))
                await buffer.apply(update("committed", final: false, id: id))
                let snap = await buffer.snapshot()
                await expect(snap.count == 1 && snap.first?.isFinal == true,
                             "stale volatile can't resurrect a committed row")
            }

            // 9. lastSegment(on:) prefers the live hypothesis; lastFinalized() ignores it.
            do {
                let buffer = TranscriptBuffer()
                await buffer.apply(update("done line", final: true, channel: .system))
                await buffer.apply(update("in progress", final: false, channel: .system))
                let last = await buffer.lastSegment(on: .system)
                let lastFinal = await buffer.lastFinalized()
                await expect(last?.text == "in progress", "lastSegment returns the volatile tail")
                await expect(lastFinal?.text == "done line", "lastFinalized returns the committed line")
            }
        }
    }

    /// Pins `ReplayOverlapTrimmer` — the word-level dedup applied at SFSpeech task
    /// seams, where the ~1.2 s audio replay makes the new task re-hear (and
    /// re-transcribe) the tail of the previous utterance.
    static func runReplayOverlapTrimmerSuite() async {
        await suite("ReplayOverlapTrimmer") {
            let tail = ReplayOverlapTrimmer.tailWords(of: "and that is a worthwhile trade.")

            await expect(ReplayOverlapTrimmer.trim("worthwhile trade. So the next step", againstTail: tail)
                         == "So the next step",
                         "replayed 2-word tail is trimmed off the new hypothesis")
            await expect(ReplayOverlapTrimmer.trim("Worthwhile TRADE so the next step", againstTail: tail)
                         == "so the next step",
                         "trim matches case/punctuation-insensitively, keeps original remainder")
            await expect(ReplayOverlapTrimmer.trim("worthwhile trade.", againstTail: tail).isEmpty,
                         "hypothesis that is pure overlap trims to empty (emission gets skipped)")
            await expect(ReplayOverlapTrimmer.trim("Completely new sentence here", againstTail: tail)
                         == "Completely new sentence here",
                         "no overlap → untouched")
            await expect(ReplayOverlapTrimmer.trim("anything at all", againstTail: [])
                         == "anything at all",
                         "empty tail → untouched")

            // Longest match wins: tail "…is a worthwhile trade", hypothesis
            // starting with 4 overlapping words drops all 4, not just 2.
            await expect(ReplayOverlapTrimmer.trim("is a worthwhile trade. Moving on", againstTail: tail)
                         == "Moving on",
                         "longest overlapping run is trimmed")

            // Only a *prefix* of the hypothesis may be trimmed — the same words
            // appearing later in the sentence must survive.
            await expect(ReplayOverlapTrimmer.trim("He said a worthwhile trade was made", againstTail: tail)
                         == "He said a worthwhile trade was made",
                         "mid-sentence repetition of the tail is not a replay overlap")

            await expect(ReplayOverlapTrimmer.tailWords(of: "one two three four five six seven eight nine ten").count == ReplayOverlapTrimmer.maxWords,
                         "tail is capped at maxWords")
        }
    }

    /// Pins the utterance-cutting rules that turn the Parakeet engine's
    /// continuous token stream into transcript lines.
    static func runTranscriptStreamSegmenterSuite() async {
        await suite("TranscriptStreamSegmenter") {
            func token(_ piece: String, _ start: TimeInterval, _ end: TimeInterval) -> StreamToken {
                StreamToken(piece: piece, startTime: start, endTime: end)
            }

            // Word assembly across drain batches: a word split over two absorb
            // calls must reassemble, not become two words.
            let assembly = TranscriptStreamSegmenter()
            var finals = assembly.absorb([token(" hel", 0.0, 0.1)])
            finals += assembly.absorb([token("lo", 0.1, 0.2), token(" world", 0.3, 0.5)])
            await expect(finals.isEmpty, "no cut during continuous speech")
            await expect(assembly.currentText == "hello world",
                         "sub-word tokens straddling a batch boundary reassemble (got \"\(assembly.currentText)\")")

            // Punctuation tokens (no leading space) attach to the open word.
            _ = assembly.absorb([token(".", 0.5, 0.55)])
            await expect(assembly.currentText == "hello world.",
                         "punctuation token extends the open word")

            // Gap cut: a word starting ≥ gapSeconds after the previous token's
            // end closes the segment; the new word opens the next one.
            let gap = TranscriptStreamSegmenter()
            _ = gap.absorb([token(" how", 0.0, 0.2), token(" are", 0.25, 0.4), token(" you?", 0.45, 0.7)])
            let gapFinals = gap.absorb([token(" Great", 2.5, 2.7)])
            await expect(gapFinals.count == 1 && gapFinals[0].text == "how are you?",
                         "≥1 s pause between words cuts the segment")
            await expect(gap.currentText == "Great", "word after the pause opens the next segment")

            // Idle cut fires only once the decoded frontier is past the last
            // token by idleSeconds — not while decode is merely catching up.
            let idle = TranscriptStreamSegmenter()
            _ = idle.absorb([token(" done", 0.0, 0.3)])
            await expect(idle.tick(decodedThrough: 1.0) == nil, "no idle cut before threshold")
            let idleFinal = idle.tick(decodedThrough: 1.5)
            await expect(idleFinal?.text == "done", "idle cut closes the trailing utterance")
            await expect(idle.currentText.isEmpty, "segment empty after idle cut")
            await expect(idle.tick(decodedThrough: 9.9) == nil, "idle cut doesn't re-fire on empty segment")

            // Pending-final flush: idempotent, keeps the segment open under the
            // same id so later emissions merge in place downstream.
            let pending = TranscriptStreamSegmenter()
            _ = pending.absorb([token(" ship", 0.0, 0.2), token(" it", 0.25, 0.4)])
            let flushId = pending.segmentId
            let flush1 = pending.takePendingFinal()
            await expect(flush1?.text == "ship it" && flush1?.segmentId == flushId,
                         "pending final carries the open segment's id and text")
            await expect(pending.takePendingFinal() == nil, "second flush with no new tokens is nil")
            _ = pending.absorb([token(" now", 0.5, 0.7)])
            let flush2 = pending.takePendingFinal()
            await expect(flush2?.text == "ship it now" && flush2?.segmentId == flushId,
                         "new tokens re-arm the flush under the same segment id")

            // A gap cut after a flush emits the full segment under that same id
            // (downstream consumers replace by id), then rotates the id.
            let cutAfterFlush = pending.absorb([token(" Next", 3.0, 3.2)])
            await expect(cutAfterFlush.count == 1 && cutAfterFlush[0].segmentId == flushId
                         && cutAfterFlush[0].text == "ship it now",
                         "natural cut re-emits the flushed segment under its original id")
            await expect(pending.segmentId != flushId, "segment id rotates after a cut")

            // finish() closes whatever is open (stream teardown).
            let teardown = TranscriptStreamSegmenter()
            _ = teardown.absorb([token(" last", 0.0, 0.2), token(" words", 0.3, 0.5)])
            await expect(teardown.finish()?.text == "last words", "finish flushes the open segment")
            await expect(teardown.finish() == nil, "finish on empty segmenter is nil")

            // Length cut: monologue with no pause closes at sentence punctuation
            // once past the soft cap.
            let long = TranscriptStreamSegmenter(
                config: .init(gapSeconds: 1.0, idleSeconds: 1.1, softMaxCharacters: 15, hardMaxCharacters: 40)
            )
            var longFinals: [SegmenterFinal] = []
            longFinals += long.absorb([token(" this", 0.0, 0.1), token(" is", 0.15, 0.2)])
            longFinals += long.absorb([token(" quite", 0.25, 0.35), token(" long.", 0.4, 0.5)])
            await expect(longFinals.count == 1 && longFinals[0].text == "this is quite long.",
                         "soft length cap cuts at sentence-final punctuation")
        }
    }

    /// Pins the shared containment-merge rule used by TranscriptBuffer,
    /// ConversationContext, and transcript.md persistence.
    static func runTranscriptDedupSuite() async {
        await suite("TranscriptDedup") {
            await expect(TranscriptDedup.merged(previous: "we ship on friday", incoming: "We ship on Friday.")
                         == "We ship on Friday.",
                         "equal content keeps the newer (better-punctuated) text")
            await expect(TranscriptDedup.merged(previous: "Okay", incoming: "okay so the plan is ready")
                         == "okay so the plan is ready",
                         "growing utterance merges to the longer text")
            await expect(TranscriptDedup.merged(previous: "The full sentence was said here.", incoming: "sentence was said")
                         == "The full sentence was said here.",
                         "shrunken re-emission keeps the fuller previous text")
            await expect(TranscriptDedup.merged(previous: "we ship", incoming: "they said we shipped it") == nil,
                         "word-level matching — 'ship' must not merge into 'shipped'")
            await expect(TranscriptDedup.merged(previous: "totally different", incoming: "another thing entirely") == nil,
                         "distinct utterances never merge")

            // Roll-up gate.
            let t0 = Date()
            await expect(TranscriptDedup.shouldRollUp(
                previousText: "and so we're gonna", previousAt: t0,
                incomingText: "be optimizing our image loading", incomingAt: t0.addingTimeInterval(1)),
                "unpunctuated mid-sentence fragment rolls up")
            await expect(!TranscriptDedup.shouldRollUp(
                previousText: "That is the whole plan for this quarter.", previousAt: t0,
                incomingText: "Now something unrelated", incomingAt: t0.addingTimeInterval(1)),
                "complete punctuated sentence does not roll up")
            await expect(TranscriptDedup.shouldRollUp(
                previousText: "Yes.", previousAt: t0,
                incomingText: "Okay, let's do it.", incomingAt: t0.addingTimeInterval(1)),
                "short punctuated fragment still rolls up (it's the same speaker turn)")
            await expect(!TranscriptDedup.shouldRollUp(
                previousText: "and so we're gonna", previousAt: t0,
                incomingText: "something after a pause", incomingAt: t0.addingTimeInterval(5)),
                "a real pause (>2.5 s) breaks the roll-up")
            let long = String(repeating: "word ", count: 130)
            await expect(!TranscriptDedup.shouldRollUp(
                previousText: long, previousAt: t0,
                incomingText: "more", incomingAt: t0.addingTimeInterval(1)),
                "length cap stops a single row from growing forever")
        }
    }

    /// Robustness simulations: drive `TranscriptBuffer` with the exact emission
    /// patterns the two engines produce over LONG passages, and assert the three
    /// user-facing guarantees: no words lost, no words duplicated, and no
    /// utterance fragmented across multiple lines.
    static func runTranscriptRobustnessSuite() async {
        await suite("Transcript robustness (long-text simulations)") {
            // Sentences carry terminal punctuation — `addsPunctuation` is on
            // for the real recognizer, and the roll-up rule uses it as the
            // "sentence complete" signal that keeps full sentences on their
            // own lines.
            let paragraph = [
                "Good morning everyone and thanks for joining the quarterly planning call on such short notice.",
                "The main topic today is the migration of our billing pipeline to the new event driven architecture.",
                "We estimated the work at six weeks but the proof of concept surfaced two integration risks worth discussing.",
                "First the legacy invoice service still writes directly to the shared database which breaks our isolation model.",
                "Second the notification system assumes synchronous confirmation and the new queue only guarantees eventual delivery.",
                "If we cannot solve the second issue by Thursday we should descope notifications from the first milestone.",
                "I would rather ship a smaller slice on time than slip the entire quarter for a nice to have.",
                "Let's assign owners for both risks before we leave the call and reconvene on Monday morning.",
            ]
            let base = Date()
            func normalizedWords(_ s: String) -> [String] {
                s.split(whereSeparator: \.isWhitespace).map { ReplayOverlapTrimmer.normalizeWord($0) }.filter { !$0.isEmpty }
            }

            // ── Simulation 1: legacy SFSpeech engine over a long monologue.
            // Per utterance: hypotheses grow a few words at a time; each new
            // recognition task re-hears the last 3 words of the previous
            // utterance (the audio replay buffer) which the trimmer must remove;
            // a synthetic final fires at the VAD boundary; the recognizer's own
            // late final for the SAME segment id lands afterwards, while the
            // next utterance's partials are already flowing.
            do {
                let buffer = TranscriptBuffer()
                var tail: [String] = []
                var previousRawWords: [String] = []
                var t = base
                var lateFinal: (id: UUID, text: String)?

                for sentence in paragraph {
                    let id = UUID()
                    let words = sentence.split(separator: " ").map(String.init)
                    let heard = previousRawWords.suffix(3) + words   // replayed tail + real speech

                    var lastEmitted = ""
                    var step = 2
                    while true {
                        let raw = heard.prefix(step).joined(separator: " ")
                        let trimmed = ReplayOverlapTrimmer.trim(raw, againstTail: tail)
                        t.addTimeInterval(0.2)
                        if !trimmed.isEmpty {
                            await buffer.apply(TranscriptUpdate(id: id, text: trimmed, isFinal: false, channel: .system, timestamp: t))
                            lastEmitted = trimmed
                        }
                        if step >= heard.count { break }
                        step = min(step + 2, heard.count)
                    }

                    // The previous utterance's LATE natural final arrives now —
                    // mid-flow of the current one, same id as its synthetic final.
                    if let late = lateFinal {
                        t.addTimeInterval(0.05)
                        await buffer.apply(TranscriptUpdate(id: late.id, text: late.text, isFinal: true, channel: .system, timestamp: t))
                        lateFinal = nil
                    }

                    // VAD boundary → synthetic final for this utterance.
                    t.addTimeInterval(0.6)
                    await buffer.apply(TranscriptUpdate(id: id, text: lastEmitted, isFinal: true, channel: .system, timestamp: t))

                    tail = ReplayOverlapTrimmer.tailWords(of: lastEmitted)
                    previousRawWords = words
                    lateFinal = (id: id, text: lastEmitted)
                }
                if let late = lateFinal {
                    t.addTimeInterval(0.1)
                    await buffer.apply(TranscriptUpdate(id: late.id, text: late.text, isFinal: true, channel: .system, timestamp: t))
                }

                let rows = await buffer.snapshot()
                await expect(rows.count == paragraph.count,
                             "SFSpeech sim: \(paragraph.count) utterances → \(paragraph.count) lines (got \(rows.count))")
                await expect(rows.allSatisfy { $0.isFinal },
                             "SFSpeech sim: every line committed, no gray leftovers")
                let got = rows.map { normalizedWords($0.text) }.flatMap { $0 }
                let want = paragraph.map { normalizedWords($0) }.flatMap { $0 }
                await expect(got == want,
                             "SFSpeech sim: transcript preserves every word exactly once, in order (got \(got.count) words, want \(want.count))")
                for (row, sentence) in zip(rows, paragraph) {
                    await expect(normalizedWords(row.text) == normalizedWords(sentence),
                                 "SFSpeech sim: line matches its utterance (got \"\(row.text)\")")
                }
            }

            // ── Simulation 2: SpeechAnalyzer engine (macOS 26 path) over the
            // same passage. Volatile results replace each other under one
            // segment id per audio range; one final commits the range; a
            // mid-range pre-prompt flush emits an early final under the same id
            // and the utterance keeps growing afterwards.
            do {
                let buffer = TranscriptBuffer()
                var t = base
                for (index, sentence) in paragraph.enumerated() {
                    let id = UUID()
                    let words = sentence.split(separator: " ").map(String.init)
                    var step = 3
                    var flushed = false
                    while true {
                        let text = words.prefix(step).joined(separator: " ")
                        t.addTimeInterval(0.15)
                        await buffer.apply(TranscriptUpdate(id: id, text: text, isFinal: false, channel: .system, timestamp: t))
                        // On every third utterance, simulate the user prompting
                        // the AI mid-sentence: the flush commits the current
                        // hypothesis early, then speech continues.
                        if index % 3 == 0, !flushed, step >= words.count / 2 {
                            t.addTimeInterval(0.05)
                            await buffer.apply(TranscriptUpdate(id: id, text: text, isFinal: true, channel: .system, timestamp: t))
                            flushed = true
                        }
                        if step >= words.count { break }
                        step = min(step + 3, words.count)
                    }
                    t.addTimeInterval(0.4)
                    await buffer.apply(TranscriptUpdate(id: id, text: sentence, isFinal: true, channel: .system, timestamp: t))
                }

                let rows = await buffer.snapshot()
                await expect(rows.count == paragraph.count,
                             "SpeechAnalyzer sim: \(paragraph.count) ranges → \(paragraph.count) lines (got \(rows.count))")
                await expect(rows.allSatisfy { $0.isFinal },
                             "SpeechAnalyzer sim: every line committed")
                for (row, sentence) in zip(rows, paragraph) {
                    await expect(row.text == sentence,
                                 "SpeechAnalyzer sim: mid-utterance flush didn't truncate or split the line (got \"\(row.text)\")")
                }
            }

            // ── Simulation 3: rapid two-channel conversation. Partials from Me
            // and Other interleave; each channel keeps exactly one live row and
            // committed lines land in speaking order without cross-contamination.
            do {
                let buffer = TranscriptBuffer()
                var t = base
                let meId = UUID(), otherId = UUID()
                await buffer.apply(TranscriptUpdate(id: otherId, text: "Could you walk", isFinal: false, channel: .system, timestamp: t))
                t.addTimeInterval(0.1)
                await buffer.apply(TranscriptUpdate(id: meId, text: "Sure, one", isFinal: false, channel: .microphone, timestamp: t))
                t.addTimeInterval(0.1)
                await buffer.apply(TranscriptUpdate(id: otherId, text: "Could you walk us through the rollout plan?", isFinal: false, channel: .system, timestamp: t))
                t.addTimeInterval(0.1)
                await buffer.apply(TranscriptUpdate(id: meId, text: "Sure, one moment please.", isFinal: false, channel: .microphone, timestamp: t))

                let live = await buffer.snapshot()
                await expect(live.count == 2, "two channels → exactly two live rows (got \(live.count))")
                await expect(live.contains { $0.channel == .system && $0.text == "Could you walk us through the rollout plan?" },
                             "system row shows its own latest hypothesis")
                await expect(live.contains { $0.channel == .microphone && $0.text == "Sure, one moment please." },
                             "mic row shows its own latest hypothesis")

                t.addTimeInterval(0.2)
                await buffer.apply(TranscriptUpdate(id: otherId, text: "Could you walk us through the rollout plan?", isFinal: true, channel: .system, timestamp: t))
                t.addTimeInterval(0.2)
                await buffer.apply(TranscriptUpdate(id: meId, text: "Sure, one moment please.", isFinal: true, channel: .microphone, timestamp: t))

                let done = await buffer.snapshot()
                await expect(done.count == 2 && done.allSatisfy { $0.isFinal },
                             "both utterances committed to exactly two lines")
                await expect(done.first?.channel == .system && done.last?.channel == .microphone,
                             "committed lines keep speaking order")
            }

            // ── Simulation 4: short phrases in rapid succession are one
            // speaker turn — they roll up into a single readable line (the
            // Meet/Teams paragraph behavior). The same phrases separated by
            // real pauses stay on their own lines.
            do {
                let buffer = TranscriptBuffer()
                var t = base
                for phrase in ["Yes.", "Okay, let's do it.", "Sounds good.", "Ship it."] {
                    let id = UUID()
                    t.addTimeInterval(0.3)
                    await buffer.apply(TranscriptUpdate(id: id, text: phrase, isFinal: false, channel: .microphone, timestamp: t))
                    t.addTimeInterval(0.3)
                    await buffer.apply(TranscriptUpdate(id: id, text: phrase, isFinal: true, channel: .microphone, timestamp: t))
                }
                let rows = await buffer.snapshot()
                // Fragments join while the line is still short; once the rolled
                // line is a full punctuated sentence, the next phrase starts a
                // new row — paragraphs grow, but bounded at sentence edges.
                await expect(rows.count == 2,
                             "rapid short phrases join into sentence-bounded lines (got \(rows.count))")
                await expect(rows.map(\.text) == ["Yes. Okay, let's do it. Sounds good.", "Ship it."],
                             "joined lines keep every phrase in order (got \(rows.map(\.text)))")

                let paused = TranscriptBuffer()
                var t2 = base
                for phrase in ["Yes.", "Okay, let's do it.", "Sounds good.", "Ship it."] {
                    let id = UUID()
                    t2.addTimeInterval(4.0)
                    await paused.apply(TranscriptUpdate(id: id, text: phrase, isFinal: true, channel: .microphone, timestamp: t2))
                }
                let pausedRows = await paused.snapshot()
                await expect(pausedRows.count == 4,
                             "pause-separated phrases keep their own lines (got \(pausedRows.count))")
            }

            // ── Simulation 5: the real-world finalization storm (verbatim
            // fragment sequence from a user transcript where one spoken
            // sentence — "Suspense isn't just about loading data, it's also
            // about loading really any asynchronous thing and so we…" — was
            // shredded into ~20 garbled rows). Containment absorbs the
            // duplicates; roll-up joins the rest. The storm must collapse to a
            // single line instead of a wall of fragments.
            do {
                let buffer = TranscriptBuffer()
                var t = base
                let fragments = [
                    "So sus", "Suspense isn't just", "Spencer",
                    "Fence isn't just about loading data", "Just about load",
                    "About loading data", "Outloading data", "Loading data",
                    "Did it", "Say it", "It's also", "It", "Also about",
                    "How about", "load", "Loading", "Really", "any",
                    "asynchronous", "As", "Asynchronous",
                    "Synchronous thing and so we",
                ]
                for fragment in fragments {
                    t.addTimeInterval(0.3)
                    await buffer.apply(TranscriptUpdate(id: UUID(), text: fragment, isFinal: true, channel: .system, timestamp: t))
                }
                let rows = await buffer.snapshot()
                await expect(rows.count <= 2,
                             "storm of \(fragments.count) fragment finals collapses to ≤2 lines (got \(rows.count))")
                let joinedWords = rows.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
                let inputWords = fragments.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
                await expect(joinedWords <= inputWords,
                             "collapse never invents text (got \(joinedWords) words from \(inputWords))")
                await expect(rows.allSatisfy { $0.isFinal }, "storm lines are committed")
            }
        }
    }

    /// End-to-end integration test: synthesize a known sentence via `AVSpeechSynthesizer`,
    /// feed the resulting audio buffers (converted to our canonical format) directly into
    /// `AppleSpeechTranscriber`, and verify a non-empty transcript comes back. Skipped if
    /// the toolchain doesn't have Speech Recognition authorized — that's a TCC environment
    /// issue, not a code bug, and we report it as such.
    /// End-to-end probe of the Parakeet engine: real model download + CoreML
    /// load + streaming decode + segmentation, fed with `say`-synthesized
    /// speech. Opt-in (downloads ~600 MB on first run, pre-warming the same
    /// cache the app uses): `WP_PARAKEET_INTEGRATION=1 swift run SmokeTests`.
    static func runParakeetIntegrationSuite() async {
        await suite("Parakeet (integration)") {
            guard ProcessInfo.processInfo.environment["WP_PARAKEET_INTEGRATION"] == "1" else {
                print("  ⓘ Set WP_PARAKEET_INTEGRATION=1 to run the Parakeet end-to-end probe (first run downloads ~600 MB).")
                return
            }

            // Synthesize a known phrase to a file with the system voice.
            let phrase = "The quick brown fox jumps over the lazy dog"
            let aiff = FileManager.default.temporaryDirectory
                .appendingPathComponent("wp-parakeet-probe-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: aiff) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", aiff.path, phrase]
            do {
                try say.run()
                say.waitUntilExit()
            } catch {
                await expect(false, "say(1) failed: \(error.localizedDescription)")
                return
            }
            guard say.terminationStatus == 0 else {
                await expect(false, "say(1) exited with status \(say.terminationStatus)")
                return
            }

            let transcriber = ParakeetTranscriber(statusNote: { print("  ⓘ \($0)") })
            do {
                try await transcriber.start(enabledChannels: [.system])
            } catch {
                await expect(false, "ParakeetTranscriber.start() threw: \(error.localizedDescription)")
                return
            }
            defer { transcriber.stop() }

            actor FinalCollector {
                var finals: [String] = []
                func append(_ text: String) { finals.append(text) }
                func snapshot() -> [String] { finals }
            }
            let collector = FinalCollector()
            let collectorTask = Task {
                for await update in transcriber.transcripts where update.isFinal {
                    await collector.append(update.text)
                }
            }

            // Feed the synthesized speech, then enough silence to cover the
            // engine's ~2 s lookahead plus the idle cut.
            do {
                let file = try AVAudioFile(forReading: aiff)
                let canonical = CanonicalAudioFormat.make()
                guard let converter = AVAudioConverter(from: file.processingFormat, to: canonical) else {
                    await expect(false, "no converter for \(file.processingFormat)")
                    return
                }
                let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
                while file.framePosition < file.length {
                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                    try file.read(into: inBuf, frameCount: chunk)
                    guard inBuf.frameLength > 0 else { break }
                    if let out = StreamingAudioConverter.convert(inBuf, using: converter, label: "ParakeetProbe") {
                        transcriber.feed(out, channel: .system)
                    }
                }
                guard let silence = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: 1600) else { return }
                silence.frameLength = 1600 // 100 ms of zeros
                for _ in 0..<60 { transcriber.feed(silence, channel: .system) }
            } catch {
                await expect(false, "feeding audio threw: \(error.localizedDescription)")
                return
            }

            // Give the pump time to decode and idle-cut, then check the finals.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !(await collector.snapshot()).isEmpty { break }
            }
            collectorTask.cancel()
            let finals = await collector.snapshot()
            let combined = finals.joined(separator: " ").lowercased()
            print("  ⓘ Parakeet finals: \(finals)")
            await expect(combined.contains("quick brown fox"), "decoded phrase contains 'quick brown fox' (got: \"\(combined)\")")
            await expect(combined.contains("lazy dog"), "decoded phrase contains 'lazy dog' (got: \"\(combined)\")")
        }
    }

    static func runSessionStoreParsingSuite() async {
        await suite("SessionStore.parseChatMarkdown") {
            let md = """
            # Chat

            _Conversation between you and the AI._

            ## You [10:00:01]

            What did we decide?

            ## Assistant [10:00:03]

            Summary below.

            ## Decisions

            - ship it

            ## Follow-ups

            - none

            ## System [10:00:10]

            Note text.
            """
            let messages = SessionStore.parseChatMarkdown(md)
            await expect(messages.count == 3,
                         "H2 headings inside a body must not split the turn (got \(messages.count) turns)")
            guard messages.count == 3 else { return }
            await expect(messages[0].role == .user, "first turn parses as user")
            await expect(messages[0].text == "What did we decide?", "user body round-trips")
            await expect(messages[1].role == .assistant, "second turn parses as assistant")
            await expect(messages[1].text.contains("## Decisions") && messages[1].text.contains("## Follow-ups"),
                         "assistant body keeps its own markdown headings")
            await expect(messages[2].role == .system, "third turn parses as system")

            // Malformed header stays in the previous body rather than being dropped.
            let sloppy = "## Assistant [09:00:00]\n\nline one\n## Not A Header\nline two\n"
            let parsed = SessionStore.parseChatMarkdown(sloppy)
            await expect(parsed.count == 1, "non-header ## line must not start a new turn")
            await expect(parsed.first?.text.contains("line two") == true,
                         "content after a non-header ## line is preserved")
        }
    }

    static func runSpeechRecognitionIntegrationSuite() async {
        await suite("SpeechRecognition (integration)") {
            let auth = SFSpeechRecognizer.authorizationStatus()
            guard auth == .authorized else {
                print("  ⓘ Speech recognition not authorized on this machine (status=\(auth.rawValue)). Skipping integration test.")
                return
            }

            let transcriber = AppleSpeechTranscriber(locale: Locale(identifier: "en-US"))
            do {
                try await transcriber.start(enabledChannels: [.microphone])
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

    /// Drives the `ResourceGovernor` state machine with a controllable clock (we pass
    /// the monotonic `now` ourselves) and synthetic samples. Pins the tier transitions:
    /// CPU sustain, memory cap, thermal short-circuit, and the Tier-1 → Tier-2/recover
    /// fork. No real CPU/memory/thermal readings are involved — the module is pure.
    static func runResourceGovernorSuite() async {
        await suite("ResourceGovernor") {
            let config = ResourceGovernorConfig.default

            func nominal(cpu: Double = 10, mem: UInt64 = 200_000_000,
                         thermal: ProcessInfo.ThermalState = .nominal) -> ResourceSample {
                ResourceSample(cpuPercent: cpu, memoryBytes: mem, thermalState: thermal)
            }

            // Below every threshold → .ok.
            do {
                let gov = ResourceGovernor(config: config)
                await expect(gov.evaluate(nominal(), at: 0) == .ok,
                             "below-threshold sample is .ok")
                await expect(gov.evaluate(nominal(cpu: 65), at: 1) == .ok,
                             "CPU under threshold stays .ok")
            }

            // CPU over threshold but not yet sustained → .ok; sustained → .tier1Pause.
            do {
                let gov = ResourceGovernor(config: config)
                await expect(gov.evaluate(nominal(cpu: 85), at: 0) == .ok,
                             "CPU over threshold but t=0 is not yet sustained → .ok")
                await expect(gov.evaluate(nominal(cpu: 85), at: 10) == .ok,
                             "still within the sustain window → .ok")
                await expect(gov.evaluate(nominal(cpu: 85), at: config.cpuSustainSeconds) == .tier1Pause,
                             "CPU sustained past the window → .tier1Pause")
            }

            // A dip below threshold resets the sustain clock — no accumulation.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                await expect(gov.evaluate(nominal(cpu: 50), at: 10) == .ok,
                             "CPU drops mid-window → clock resets")
                await expect(gov.evaluate(nominal(cpu: 85), at: 25) == .ok,
                             "re-crossing restarts the sustain window from scratch")
                await expect(gov.evaluate(nominal(cpu: 85), at: 25 + config.cpuSustainSeconds) == .tier1Pause,
                             "sustained again from the restart point → .tier1Pause")
            }

            // Memory over cap → .tier1Pause immediately (no sustain requirement).
            do {
                let gov = ResourceGovernor(config: config)
                await expect(gov.evaluate(nominal(mem: config.memoryTier1Bytes + 1), at: 0) == .tier1Pause,
                             "memory over cap engages Tier-1 immediately")
            }

            // Thermal .serious → .tier2Stop (and .critical likewise), from normal.
            do {
                let gov = ResourceGovernor(config: config)
                await expect(gov.evaluate(nominal(thermal: .serious), at: 0) == .tier2Stop,
                             "thermal .serious short-circuits to .tier2Stop")
                let gov2 = ResourceGovernor(config: config)
                await expect(gov2.evaluate(nominal(thermal: .critical), at: 0) == .tier2Stop,
                             "thermal .critical short-circuits to .tier2Stop")
            }

            // Load still high 15s after Tier-1 → .tier2Stop.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                let t1 = config.cpuSustainSeconds
                await expect(gov.evaluate(nominal(cpu: 85), at: t1) == .tier1Pause,
                             "enters Tier-1 once sustained")
                await expect(gov.evaluate(nominal(cpu: 85), at: t1 + 5) == .tier1Pause,
                             "still within escalation window → remains .tier1Pause")
                await expect(gov.evaluate(nominal(cpu: 85), at: t1 + config.tier2EscalationSeconds) == .tier2Stop,
                             "load high through the escalation window → .tier2Stop")
            }

            // Load recovering after Tier-1 → back to .ok.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                let t1 = config.cpuSustainSeconds
                await expect(gov.evaluate(nominal(cpu: 85), at: t1) == .tier1Pause,
                             "enters Tier-1 once sustained")
                await expect(gov.evaluate(nominal(cpu: 40), at: t1 + 5) == .ok,
                             "load recovers below threshold → back to .ok")
                await expect(gov.tier == .normal, "recovery returns the governor to .normal")
            }

            // Tier-2 is terminal until reset().
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(thermal: .serious), at: 0)
                await expect(gov.evaluate(nominal(), at: 1) == .tier2Stop,
                             "stays stopped after Tier-2 even on a clean sample")
                gov.reset()
                await expect(gov.evaluate(nominal(), at: 2) == .ok,
                             "reset() clears Tier-2 back to .ok")
            }
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

            // Per-channel state: a Me-side question + Me-side pause should fire
            // and carry channel=.microphone, so the coordinator can re-check the
            // "from Me" toggle before calling the AI.
            do {
                let engine = TriggerEngine()
                await engine.consider(segment: micSegment("How would you scale this service?"))
                await engine.absorb(.speechEnded(channel: .microphone, at: Date().addingTimeInterval(-1.0), duration: 2.0, silenceLeading: 0))
                let event = await collectFirstEvent(from: engine, within: 0.5)
                await expect(event != nil, "fires on a mic-channel question")
                await expect(event?.channel == .microphone, "event carries the mic channel")
            }

            // Channel isolation: a Me-side pause must not flush an Other-side
            // pending candidate. Without per-channel state this would
            // mistakenly fire as soon as either side paused.
            do {
                let engine = TriggerEngine()
                await engine.consider(segment: systemSegment("How would you scale this?"))
                await engine.absorb(.speechEnded(channel: .microphone, at: Date().addingTimeInterval(-1.0), duration: 1.0, silenceLeading: 0))
                let event = await collectFirstEvent(from: engine, within: 0.4)
                await expect(event == nil, "Other-side candidate doesn't fire on a Me-side pause")
            }
        }
    }

    /// Guards the streaming conversion contract: one converter instance fed many
    /// sequential Process-Tap-sized buffers (10 ms, 48 kHz stereo → 16 kHz mono)
    /// must keep producing output for every buffer. This is the regression the
    /// old per-buffer `reset()` + `.endOfStream` pattern was working around (a
    /// latched converter returns 0 frames from call 2 onward) — the `.noDataNow`
    /// idiom must not reintroduce it, and must not leak samples to re-priming.
    static func runStreamingAudioConverterSuite() async {
        await suite("StreamingAudioConverter") {
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make()) else {
                await expect(false, "could not build test formats/converter")
                return
            }
            let bufferFrames: AVAudioFrameCount = 480 // 10 ms @ 48 kHz — Process Tap callback size
            let bufferCount = 50
            var totalOutputFrames = 0
            var dryBuffersAfterFirst = 0
            var phase = 0.0
            for i in 0..<bufferCount {
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferFrames),
                      let channels = input.floatChannelData.map({ [$0[0], $0[1]] }) else { continue }
                input.frameLength = bufferFrames
                for f in 0..<Int(bufferFrames) {
                    let sample = Float(sin(phase))
                    phase += 2.0 * Double.pi * 440.0 / 48000.0
                    channels[0][f] = sample
                    channels[1][f] = sample
                }
                if let out = StreamingAudioConverter.convert(input, using: converter, label: "smoke-test") {
                    totalOutputFrames += Int(out.frameLength)
                } else if i > 0 {
                    dryBuffersAfterFirst += 1
                }
            }
            let expected = bufferCount * Int(bufferFrames) / 3 // 48 kHz → 16 kHz
            await expect(dryBuffersAfterFirst == 0,
                         "converter produced output for every buffer after priming (latch regression guard, \(dryBuffersAfterFirst) dry)")
            await expect(totalOutputFrames >= Int(Double(expected) * 0.95),
                         "≥95% of expected samples survive 50 sequential conversions (got \(totalOutputFrames)/\(expected))")
        }
    }

    static func runUpdateCheckerSuite() async {
        await suite("UpdateChecker.isVersion") {
            await expect(UpdateChecker.isVersion("0.1.13", newerThan: "0.1.12"), "patch bump is newer")
            await expect(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.12"), "minor bump beats higher patch")
            await expect(UpdateChecker.isVersion("1.0.0", newerThan: "0.9.9"), "major bump is newer")
            await expect(UpdateChecker.isVersion("0.1.10", newerThan: "0.1.9"), "numeric compare, not lexicographic")
            await expect(!UpdateChecker.isVersion("0.1.12", newerThan: "0.1.12"), "equal versions are not newer")
            await expect(!UpdateChecker.isVersion("0.1.11", newerThan: "0.1.12"), "older is not newer")
            await expect(UpdateChecker.isVersion("0.1.12.1", newerThan: "0.1.12"), "extra component counts")
            await expect(!UpdateChecker.isVersion("0.1.12", newerThan: "0.1.12.0"), "trailing zero is equal")
            await expect(!UpdateChecker.isVersion("garbage", newerThan: "0.1.12"), "malformed tag never claims newer")
        }
    }

}
