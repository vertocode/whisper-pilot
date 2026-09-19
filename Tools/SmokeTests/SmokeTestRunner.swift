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
        await runSessionStorePersistenceSuite()
        await runInstallDiagnosticsSuite()
        await runOnboardingEligibilitySuite()
        await runEngineFallbackNoteSuite()
        await runSaveHealthSuite()
        await runSessionCountCacheSuite()
        await runLogRotationSuite()
        await runAIProviderSuite()
        await runSingleInstanceSuite()
        await runKeychainSuite()
        await runListeningActivitySuite()
        await runMenuLayoutSuite()
        await runDragHelperPlacementSuite()
        await runPermissionMappingSuite()
        await runTranslationLayoutSuite()
        await runTranslationBufferSuite()
        await runTranslationQueueSuite()
        await runTranslationPersistenceSuite()
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

            // Budget clamps: a resumed multi-hour session must not paste the whole
            // transcript.md/chat.md into the prompt. Tail is kept (recent end
            // matters live); user context files keep their head.
            var bigSnapshot = snapshotFor()
            bigSnapshot.priorTranscriptMarkdown =
                "OLDEST-LINE\n" + String(repeating: "x", count: PromptBuilder.priorTranscriptBudget * 2) + "\nNEWEST-LINE"
            bigSnapshot.globalContextBlock =
                "DOC-HEAD\n" + String(repeating: "y", count: PromptBuilder.contextFileBudget * 2) + "\nDOC-TAIL"
            let clamped = PromptBuilder.build(context: bigSnapshot, history: [], question: "?", style: .concise)
            await expect(clamped.context.contains("NEWEST-LINE"), "prior transcript keeps its tail")
            await expect(!clamped.context.contains("OLDEST-LINE"), "prior transcript head is truncated")
            await expect(clamped.context.contains("DOC-HEAD"), "context file keeps its head")
            await expect(!clamped.context.contains("DOC-TAIL"), "context file tail is truncated")
            await expect(clamped.context.contains("truncated"), "truncation is marked in the prompt")
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

            let withOrigin = """
            ## You [10:01:00]

            <!-- whisper-pilot:origin=detectedQuestion -->

            Why did latency increase?

            ## Assistant [10:01:01]

            <!-- whisper-pilot:origin=detectedQuestion -->

            Queue depth increased.
            """
            let originated = SessionStore.parseChatMarkdown(withOrigin)
            await expect(originated.count == 2, "origin metadata does not create extra turns")
            await expect(originated.allSatisfy { $0.origin == .detectedQuestion },
                         "detected-question origin round-trips for question and answer")
            await expect(originated.first?.text == "Why did latency increase?",
                         "origin metadata is removed from displayed text")
            await expect(!SessionStore.strippingChatMetadata(withOrigin).contains("whisper-pilot:origin"),
                         "origin metadata is removed from resumed AI context")

            // Malformed header stays in the previous body rather than being dropped.
            let sloppy = "## Assistant [09:00:00]\n\nline one\n## Not A Header\nline two\n"
            let parsed = SessionStore.parseChatMarkdown(sloppy)
            await expect(parsed.count == 1, "non-header ## line must not start a new turn")
            await expect(parsed.first?.text.contains("line two") == true,
                         "content after a non-header ## line is preserved")
        }
    }

    static func runSessionStorePersistenceSuite() async {
        await suite("SessionStore chat persistence") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)

            do {
                let session = try await store.createSession(name: "Persistence regression")
                await store.appendChatTurn(
                    role: "You",
                    text: "What should we ship?",
                    origin: .detectedQuestion,
                    at: Date(),
                    to: session.id
                )
                await store.appendChatTurn(
                    role: "Assistant",
                    text: "Ship the stable build.",
                    origin: .detectedQuestion,
                    at: Date(),
                    to: session.id
                )

                let firstResume = await store.loadChatMessages(session.id)
                await expect(firstResume.map(\.text) == ["What should we ship?", "Ship the stable build."],
                             "auto-detected question and answer reload in order")
                await expect(firstResume.allSatisfy { $0.origin == .detectedQuestion },
                             "auto-detected question and answer restore origin")

                let secondResume = await store.loadChatMessages(session.id)
                await expect(secondResume.count == 2,
                             "repeated resume does not duplicate persisted turns")
            } catch {
                await expect(false, "session persistence setup failed: \(error.localizedDescription)")
            }
        }

        await suite("SessionStore metadata recovery") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let session = try await store.createSession(name: "Recover me")
                try Data("{broken".utf8).write(
                    to: root.appendingPathComponent(session.folderName).appendingPathComponent("metadata.json")
                )
                let sessions = await store.listSessions()
                await expect(sessions.count == 1, "corrupt metadata does not hide session data")
                await expect(sessions.first?.folderName == session.folderName,
                             "recovered session keeps original folder identity")
            } catch {
                await expect(false, "metadata recovery setup failed: \(error.localizedDescription)")
            }
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

            // Load recovering after Tier-1 → back to .ok, but only after the
            // recovery sustain (hysteresis): a single calm sample must NOT
            // release the tier, or load oscillating around the threshold flaps
            // Tier-1 on/off and cancels in-flight AI completions each time.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                let t1 = config.cpuSustainSeconds
                await expect(gov.evaluate(nominal(cpu: 85), at: t1) == .tier1Pause,
                             "enters Tier-1 once sustained")
                await expect(gov.evaluate(nominal(cpu: 40), at: t1 + 5) == .tier1Pause,
                             "first calm sample holds Tier-1 (recovery sustain running)")
                await expect(gov.evaluate(nominal(cpu: 40), at: t1 + 5 + config.recoverySeconds) == .ok,
                             "calm through the recovery window → back to .ok")
                await expect(gov.tier == .normal, "recovery returns the governor to .normal")
            }

            // Middle band (release < cpu ≤ engage) holds Tier-1: neither
            // releases nor escalates.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                let t1 = config.cpuSustainSeconds
                _ = gov.evaluate(nominal(cpu: 85), at: t1)
                await expect(gov.evaluate(nominal(cpu: 65), at: t1 + config.tier2EscalationSeconds + 10) == .tier1Pause,
                             "middle-band load holds Tier-1 without escalating to Tier-2")
                await expect(gov.tier == .tier1, "middle band keeps the governor in .tier1")
            }

            // Spiky-but-high load: brief dips within the tolerance must not
            // reset the sustain run — previously a single 750 ms dip restarted
            // the 20 s clock and the valve never engaged under real spiky load.
            do {
                let gov = ResourceGovernor(config: config)
                _ = gov.evaluate(nominal(cpu: 85), at: 0)
                _ = gov.evaluate(nominal(cpu: 85), at: 9)
                _ = gov.evaluate(nominal(cpu: 60), at: 9.75)   // one 750 ms dip
                _ = gov.evaluate(nominal(cpu: 85), at: 10.5)
                await expect(gov.evaluate(nominal(cpu: 85), at: config.cpuSustainSeconds) == .tier1Pause,
                             "sub-tolerance dips don't reset the sustain clock")
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

            // Re-arm: speech-ended arriving *before* the pause requirement has
            // elapsed must not drop the candidate. If no further transcript
            // partial arrives (recognizer already delivered its last
            // hypothesis), the engine's internal retry timer has to fire once
            // the pause gate opens on its own.
            do {
                let engine = TriggerEngine()
                await engine.consider(segment: systemSegment("How would you scale this?"))
                await engine.absorb(.speechEnded(channel: .system, at: Date(), duration: 2.0, silenceLeading: 0))
                let event = await collectFirstEvent(from: engine, within: 1.5)
                await expect(event != nil, "re-arm timer fires the held candidate once the pause elapses")
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

    // MARK: - Live translation

    /// Stand-in translator. Records every call so tests can assert on *how
    /// many* translations were issued, which is the whole point of the debounce
    /// and generation machinery.
    final class FakeTranslator: TranslationProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private let delay: Duration

        init(delay: Duration = .zero) { self.delay = delay }

        func translate(_ text: String) async throws -> String {
            lock.withLock { recorded.append(text) }
            if delay != .zero { try? await Task.sleep(for: delay) }
            return "<\(text)>"
        }

        func prewarm() async {}

        var calls: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    actor TranslationSink {
        private(set) var results: [UUID: String] = [:]
        private(set) var writeCount = 0
        func record(_ id: UUID, _ text: String) {
            results[id] = text
            writeCount += 1
        }
    }

    static func volatileSystemSegment(id: UUID = UUID(), _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, text: text, isFinal: false, channel: .system,
                          startedAt: Date(), updatedAt: Date())
    }

    static func finalSystemSegment(id: UUID = UUID(), _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, text: text, isFinal: true, channel: .system,
                          startedAt: Date(), updatedAt: Date())
    }

    /// Long enough for a finals path (no debounce) to complete, short enough to
    /// keep the suite quick.
    static let translationSettleDelay: Duration = .milliseconds(150)

    static func runInstallDiagnosticsSuite() async {
        await suite("InstallDiagnostics (App Translocation)") {
            // Real translocation paths, as macOS produces them.
            await expect(InstallDiagnostics.isTranslocatedPath(
                "/private/var/folders/9x/abc123/T/AppTranslocation/1B2C3D4E-5F6A/d/WhisperPilot.app"),
                         "a genuine translocation mount is detected")
            await expect(InstallDiagnostics.isTranslocatedPath(
                "/var/folders/zz/x/AppTranslocation/DEADBEEF/d/WhisperPilot.app"),
                         "detected regardless of the /private prefix")

            // Normal installs must never trip this — a false positive would tell
            // a correctly-installed user to run a command that does nothing, and
            // train them to ignore the app's warnings.
            await expect(!InstallDiagnostics.isTranslocatedPath("/Applications/WhisperPilot.app"),
                         "a normal /Applications install is not translocated")
            await expect(!InstallDiagnostics.isTranslocatedPath(
                "/Users/someone/Applications/WhisperPilot.app"),
                         "a per-user Applications install is not translocated")
            await expect(!InstallDiagnostics.isTranslocatedPath(
                "/Users/someone/Downloads/WhisperPilot.app"),
                         "sitting in Downloads is not itself translocation — only the mount is")
            await expect(!InstallDiagnostics.isTranslocatedPath(
                "/Users/someone/Projects/AppTranslocationNotes/WhisperPilot.app"),
                         "a folder merely named like the marker doesn't match")
            await expect(!InstallDiagnostics.isTranslocatedPath(""),
                         "an empty path is not translocated")

            // The remedy text has to name a real path and a runnable command,
            // since users copy it verbatim into a terminal.
            await expect(InstallDiagnostics.remedyCommand.contains("xattr -dr com.apple.quarantine"),
                         "remedy clears the quarantine attribute recursively")
            await expect(InstallDiagnostics.remedyCommand.contains(InstallDiagnostics.recommendedInstallPath),
                         "remedy targets the documented install path")
            await expect(InstallDiagnostics.translocationMessage.contains(InstallDiagnostics.remedyCommand),
                         "the note shows the command even if the user doesn't press Copy")
        }
    }

    static func runSaveHealthSuite() async {
        struct Boom: Error {}
        let diskFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let noPermission = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))

        await suite("Save health") {
            var health = SaveHealth()
            await expect(health.record(.success(())) == .none, "success while healthy -> no change")
            await expect(
                health.record(.failure(diskFull)) == .started(reason: "the disk is full"),
                "first failure -> banner with the disk-full reason"
            )
            await expect(health.isFailing, "state is failing after a failure")
            await expect(health.record(.failure(diskFull)) == .none, "repeated failure -> no second banner")
            await expect(health.record(.success(())) == .recovered, "first success after failing -> recovered")
            await expect(!health.isFailing, "state is healthy after recovery")
            await expect(health.record(.success(())) == .none, "success after recovery -> no change")

            await expect(
                SaveHealth.reason(for: noPermission).contains("no permission"),
                "POSIX EACCES -> permission message"
            )
            let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
            await expect(SaveHealth.reason(for: wrapped) == "the disk is full", "underlying ENOSPC -> disk full")
            await expect(
                SaveHealth.reason(for: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)).contains("moved or deleted"),
                "missing folder -> moved or deleted message"
            )
            await expect(SaveHealth.bannerText(reason: "x").contains("not being saved"), "banner says the session is not being saved")
        }

        await suite("Assistant turn text") {
            await expect(AssistantTurnText.persisted("  \n", incomplete: true) == nil, "blank reply is not saved")
            await expect(AssistantTurnText.persisted("Done.", incomplete: false) == "Done.", "complete reply is saved as-is")
            await expect(
                AssistantTurnText.persisted("Half an ans", incomplete: true) == "Half an ans\n\n(incomplete)",
                "cut-off reply keeps its text and gets the marker"
            )
        }

        await suite("SessionStore write failures") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let session = try await store.createSession(name: "Write failures")
                let ok = await store.appendChatTurn(role: "You", text: "hi", at: Date(), to: session.id)
                await expect((try? ok.get()) != nil, "append to a healthy session reports success")

                let folder = root.appendingPathComponent(session.folderName)
                let chatURL = folder.appendingPathComponent("chat.md")
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: chatURL.path)
                let readOnly = await store.appendChatTurn(role: "You", text: "again", at: Date(), to: session.id)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chatURL.path)
                if geteuid() != 0 {
                    await expect((try? readOnly.get()) == nil, "append to a read-only file reports failure")
                }

                try FileManager.default.removeItem(at: folder)
                let gone = await store.appendTranscriptLine(channel: .system, text: "x", at: Date(), to: session.id)
                await expect((try? gone.get()) == nil, "append after the folder was deleted reports failure")
            } catch {
                await expect(false, "write failure setup failed: \(error.localizedDescription)")
            }
        }
    }

    static func runSingleInstanceSuite() async {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let older = SingleInstance.Candidate(pid: 200, launchDate: t0)
        let newer = SingleInstance.Candidate(pid: 100, launchDate: t0.addingTimeInterval(5))
        await suite("Single instance") {
            await expect(SingleInstance.copyToHandOverTo(me: newer, others: [older]) == older, "newer copy hands over to the older one")
            await expect(SingleInstance.copyToHandOverTo(me: older, others: [newer]) == nil, "older copy keeps running")
            await expect(SingleInstance.copyToHandOverTo(me: older, others: []) == nil, "alone -> keeps running")
            let tieA = SingleInstance.Candidate(pid: 10, launchDate: t0)
            let tieB = SingleInstance.Candidate(pid: 11, launchDate: t0)
            await expect(SingleInstance.copyToHandOverTo(me: tieA, others: [tieB]) == nil, "same launch time: lower pid keeps running")
            await expect(SingleInstance.copyToHandOverTo(me: tieB, others: [tieA]) == tieA, "same launch time: higher pid hands over")
            let unknown = SingleInstance.Candidate(pid: 1, launchDate: nil)
            await expect(SingleInstance.copyToHandOverTo(me: unknown, others: [older]) == older, "unknown launch date loses")
            await expect(SingleInstance.copyToHandOverTo(me: older, others: [unknown]) == nil, "known launch date beats unknown")
            await expect(
                SingleInstance.copyToHandOverTo(me: newer, others: [SingleInstance.Candidate(pid: 300, launchDate: t0.addingTimeInterval(9)), older]) == older,
                "with several copies, the oldest wins"
            )
        }
    }

    static func runSessionCountCacheSuite() async {
        await suite("Session count parsing") {
            let transcript = Data("# Transcript\n\n**Me** [10:00:00] hi\n\n**Other** [10:00:05] hello\n> pt — oi\n\nnot **bold** start\n**Me**".utf8)
            await expect(SessionStore.countTranscriptLines(transcript) == 3, "counts lines that start with ** (including the last, unterminated one)")
            await expect(SessionStore.countTranscriptLines(Data()) == 0, "empty file -> 0")
            await expect(SessionStore.countTranscriptLines(Data("*single star\n".utf8)) == 0, "one star is not a speaker line")
            let chat = Data("# Chat\n\n## You [10:00:00]\n\nhi\n\n## Assistant [10:00:01]\n\n## A heading inside a reply\n".utf8)
            await expect(SessionStore.countChatTurns(chat) == 2, "counts only well-formed turn headers")
        }

        await suite("Session list count cache") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let a = try await store.createSession(name: "Alpha")
                let b = try await store.createSession(name: "Beta")
                await store.appendTranscriptLine(channel: .system, text: "one", at: Date(), to: a.id)
                await store.appendTranscriptLine(channel: .microphone, text: "two", at: Date(), to: a.id)
                await store.appendChatTurn(role: "You", text: "q", at: Date(), to: a.id)

                func counts(_ id: SessionID, _ list: [SessionMeta]) -> (Int, Int)? {
                    list.first { $0.id == id }.map { ($0.transcriptLineCount, $0.chatTurnCount) }
                }
                let first = await store.listSessions()
                await expect(counts(a.id, first)! == (2, 1), "first list counts lines and turns")
                await expect(counts(b.id, first)! == (0, 0), "an empty session counts zero")

                let readsAfterFirst = await store.countFileReads
                _ = await store.listSessions()
                let readsAfterSecond = await store.countFileReads
                await expect(readsAfterSecond == readsAfterFirst, "an unchanged list does not re-read any file")

                await store.appendTranscriptLine(channel: .system, text: "three", at: Date(), to: a.id)
                let third = await store.listSessions()
                await expect(counts(a.id, third)! == (3, 1), "a new line shows up on the next list")
                let readsAfterThird = await store.countFileReads
                await expect(readsAfterThird == readsAfterSecond + 1, "only the changed file was re-read")

                try FileManager.default.removeItem(at: root.appendingPathComponent(b.folderName))
                let fourth = await store.listSessions()
                await expect(fourth.count == 1, "a deleted session leaves the list")
            } catch {
                await expect(false, "count cache setup failed: \(error.localizedDescription)")
            }
        }
    }

    static func runLogRotationSuite() async {
        await suite("Log rotation") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp-log-\(UUID().uuidString).log")
            defer { try? FileManager.default.removeItem(at: url) }
            let lines = (0..<200).map { "line-\($0)" }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                await expect(false, "could not open temp log")
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let fd = handle.fileDescriptor

            let size = CrashLogger.rotate(fileDescriptor: fd, at: url, keepBytes: 100)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            await expect(size == text.utf8.count && size <= 100, "file shrinks to the keep size or less")
            await expect(text.hasSuffix("line-199\n"), "newest line is kept")
            await expect(text.hasPrefix("line-"), "the kept text starts on a whole line")
            await expect(!text.contains("line-0\n"), "old lines are dropped")

            let extra = Data("after-rotation\n".utf8)
            _ = extra.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            await expect(after.hasSuffix("line-199\nafter-rotation\n"), "writes through the same descriptor append after rotation")

            let small = CrashLogger.rotate(fileDescriptor: fd, at: url, keepBytes: 1_000_000)
            await expect(small == after.utf8.count, "a file under the keep size is left whole")
        }
    }

    static func runListeningActivitySuite() async {
        await suite("Listening activity and wake recovery") {
            let activity = ListeningActivity()
            await expect(!activity.isActive, "starts idle")
            activity.begin()
            await expect(activity.isActive, "begin holds an activity")
            activity.begin()
            await expect(activity.isActive, "a second begin does not stack a second activity")
            activity.end()
            await expect(!activity.isActive, "end releases it")
            activity.end()
            await expect(!activity.isActive, "a second end is harmless")

            await expect(WakeRecovery.needsRestart(framesBefore: 500, framesAfter: 500), "no new frames after wake -> restart")
            await expect(WakeRecovery.needsRestart(framesBefore: 500, framesAfter: 0), "counter reset after wake -> restart")
            await expect(!WakeRecovery.needsRestart(framesBefore: 500, framesAfter: 620), "frames still arriving -> leave it alone")
        }
    }

    static func runMenuLayoutSuite() async {
        await suite("Menu bar layout") {
            let setup = MenuLayout.entries(needsSetup: true, listeningActive: false)
            await expect(
                setup == [.finishSetup, .separator, .settings, .separator, .about, .quit],
                "while setup is missing: Finish setup, Settings, About, Quit only"
            )
            await expect(!setup.contains(.showOverlay) && !setup.contains(.sessions), "no session entries while setup is missing")
            let idle = MenuLayout.entries(needsSetup: false, listeningActive: false)
            await expect(
                idle == [.toggleListening(running: false), .showOverlay, .separator, .sessions, .settings, .separator, .about, .quit],
                "full menu once setup is done"
            )
            let running = MenuLayout.entries(needsSetup: false, listeningActive: true)
            await expect(running.first == .toggleListening(running: true), "the first entry reflects a running session")
            await expect(!idle.contains(.finishSetup), "the full menu has no Finish setup")
            await expect(
                MenuLayout.entries(needsSetup: true, listeningActive: true) == setup,
                "a running flag does not bring session entries back while setup is missing"
            )
        }
    }

    static func runDragHelperPlacementSuite() async {
        await suite("Drag helper placement") {
            let screen = CGRect(x: 0, y: 40, width: 1440, height: 800)
            let size = CGSize(width: 430, height: 96)
            let frame = DragHelperPlacement.frame(panel: size, visibleScreen: screen)
            await expect(frame.midX == screen.midX, "centred horizontally")
            await expect(frame.minY == screen.minY + 12, "sits at the bottom of the visible area")
            await expect(screen.contains(frame), "stays inside the screen")

            let offset = CGRect(x: 1440, y: 0, width: 1000, height: 700)
            let second = DragHelperPlacement.frame(panel: size, visibleScreen: offset)
            await expect(second.midX == offset.midX && offset.contains(second), "works on a second screen")

            let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
            let squeezed = DragHelperPlacement.frame(panel: size, visibleScreen: tiny)
            await expect(squeezed.minX >= tiny.minX, "a screen narrower than the panel does not push it off the left edge")
        }
    }

    static func runEngineFallbackNoteSuite() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

        await suite("Engine fallback note") {
            await expect(
                EngineFallbackNote.reason(for: URLError(.notConnectedToInternet)).contains("no internet"),
                "offline -> says there is no internet connection"
            )
            await expect(
                EngineFallbackNote.reason(for: URLError(.timedOut)).contains("timed out"),
                "timeout -> says the download timed out"
            )
            await expect(
                EngineFallbackNote.reason(for: URLError(.cannotFindHost)).contains("can't reach"),
                "DNS failure -> says the server can't be reached"
            )
            let wrapped = NSError(domain: "FluidAudio", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
            await expect(
                EngineFallbackNote.reason(for: wrapped).contains("no internet"),
                "URLError wrapped as an underlying error is still recognized"
            )
            await expect(EngineFallbackNote.reason(for: Boom()) == "boom", "other errors keep their own message")
            let text = EngineFallbackNote.text(for: URLError(.notConnectedToInternet))
            await expect(text.contains("Apple's on-device engine"), "note names the engine now in use")
            await expect(text.contains("next time you press Play"), "note says Parakeet is retried")
            await expect(
                TranscriberError.onDeviceUnavailable("pt-BR").errorDescription?.contains("never sends audio") == true,
                "on-device-unavailable error states that audio is not sent to Apple"
            )
        }
    }

    static func runOnboardingEligibilitySuite() async {
        let allGranted = PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, systemAudio: .granted
        )
        func missing(
            mic: Bool = true,
            forceScreen: Bool = false,
            tap: Bool = true,
            _ permissions: PermissionsSnapshot,
            keychain: KeychainAccess = .noKeysStored
        ) -> [SetupItem] {
            OnboardingEligibility.missing(
                captureMicrophone: mic,
                requiresScreenRecording: forceScreen,
                processTapSupported: tap,
                permissions: permissions,
                keychain: keychain
            )
        }

        await suite("Onboarding eligibility") {
            await expect(missing(allGranted).isEmpty, "everything granted -> nothing missing")

            let fresh = PermissionsSnapshot()
            await expect(
                missing(fresh) == [.microphone, .speechRecognition, .systemAudio],
                "fresh install needs mic, speech and system audio; screen recording stays optional"
            )
            await expect(
                missing(mic: false, fresh) == [.speechRecognition, .systemAudio],
                "disabled microphone capture does not require the microphone permission"
            )

            var noScreen = allGranted
            noScreen.screenRecording = .unknown
            await expect(missing(noScreen).isEmpty, "optional Screen Recording is never required on the Process Tap path")
            await expect(
                missing(forceScreen: true, noScreen) == [.screenRecording],
                "ScreenCaptureKit path requires Screen Recording and drops the tap permission"
            )
            var noTap = fresh
            noTap.microphone = .granted
            noTap.speechRecognition = .granted
            await expect(
                missing(tap: false, noTap) == [],
                "macOS without Process Taps only needs Screen Recording when it is required by the caller"
            )
            await expect(
                missing(allGranted, keychain: .needsUnlock) == [.keychain],
                "a saved key this build hasn't unlocked is missing"
            )
            await expect(
                missing(allGranted, keychain: .denied).isEmpty,
                "a denied Keychain is not re-requested automatically"
            )
            await expect(
                missing(allGranted, keychain: .ready).isEmpty && missing(allGranted, keychain: .noKeysStored).isEmpty,
                "ready or empty Keychain needs nothing"
            )

            let current = SettingsStore.currentOnboardingVersion
            func present(_ completed: Int, deferred: Bool = false, _ items: [SetupItem], hasKey: Bool = true) -> Bool {
                OnboardingEligibility.shouldPresent(
                    completedVersion: completed, currentVersion: current,
                    deferredForThisBuild: deferred, missing: items, hasAIKey: hasKey
                )
            }
            await expect(present(0, [.microphone]), "first run with a missing permission shows onboarding")
            await expect(present(0, []) == false, "first run with everything granted and a key saved skips onboarding")
            await expect(
                present(0, [], hasKey: false),
                "first run with every permission granted but no AI key still shows onboarding, so the key step is never skipped"
            )
            await expect(
                present(current, [], hasKey: false) == false,
                "finished onboarding does not come back just because there is no key"
            )
            await expect(
                present(current, [.microphone, .systemAudio]) == false,
                "finished onboarding is not reopened for a permission turned off later"
            )
            await expect(present(current, [.keychain]), "an updated build that needs the Keychain approved again reopens onboarding")
            await expect(present(current, deferred: true, [.keychain]) == false, "\"Set up later\" silences onboarding for this build")
            await expect(present(0, deferred: true, [.microphone]) == false, "deferred first-run onboarding stays closed until the next build")
            await expect(present(0, deferred: true, [], hasKey: false) == false, "closing onboarding without a key also stays closed for this build")
            await expect(present(current - 1, [.systemAudio]), "a newer onboarding version shows once for the items it added")

            var someGranted = PermissionsSnapshot()
            someGranted.microphone = .granted
            await expect(
                OnboardingEligibility.startPoint(completedVersion: 0, missing: [.microphone], permissions: PermissionsSnapshot()) == .welcome,
                "a brand-new user starts on the welcome screen"
            )
            await expect(
                OnboardingEligibility.startPoint(completedVersion: 0, missing: [.speechRecognition], permissions: someGranted) == .permissions,
                "someone who already granted something skips the welcome screen (for example after macOS restarts the app)"
            )
            await expect(
                OnboardingEligibility.startPoint(completedVersion: 0, missing: [], permissions: allGranted) == .ai,
                "everything granted -> only the AI key step is left"
            )
            await expect(
                OnboardingEligibility.startPoint(completedVersion: current, missing: [.keychain], permissions: allGranted) == .permissions,
                "a returning user goes straight to the permissions screen"
            )
        }
    }

    static func runTranslationLayoutSuite() async {
        await suite("TranslationLayout") {
            await expect(TranslationLayout.auto.resolved(forTextWidth: 680) == .sideBySide,
                         "auto goes side-by-side at Standard/Focus width")
            await expect(TranslationLayout.auto.resolved(forTextWidth: 428) == .stacked,
                         "auto stacks at the default Sidebar width (428pt)")
            await expect(TranslationLayout.auto.resolved(forTextWidth: 0) == .stacked,
                         "unmeasured width stacks rather than cramming two columns")
            await expect(TranslationLayout.sideBySide.resolved(forTextWidth: 100) == .sideBySide,
                         "explicit side-by-side ignores the threshold")
            await expect(TranslationLayout.stacked.resolved(forTextWidth: 2000) == .stacked,
                         "explicit stacked ignores the threshold")
            await expect(TranslationLayout.defaultSourceWidthFraction < 0.5,
                         "source starts with less than half — translations run longer than English")

            // Drag clamping: a stored or dragged value can never render a
            // column too narrow to read.
            await expect(SettingsStore.clampSourceFraction(0.5) == 0.5, "mid-range fraction passes through")
            await expect(SettingsStore.clampSourceFraction(0.01) == Double(TranslationLayout.minSourceWidthFraction),
                         "an extreme drag left clamps to the minimum")
            await expect(SettingsStore.clampSourceFraction(9.9) == Double(TranslationLayout.maxSourceWidthFraction),
                         "an extreme drag right clamps to the maximum")
            await expect(TranslationLayout.collapseToTranslationThreshold < TranslationLayout.minSourceWidthFraction,
                         "collapse threshold sits outside the clamp, so it takes a deliberate shove")
            await expect(TranslationLayout.collapseToSourceThreshold > TranslationLayout.maxSourceWidthFraction,
                         "same on the other edge")
        }

        await suite("TranslationColumnMode") {
            await expect(TranslationColumnMode.both.showsSource && TranslationColumnMode.both.showsTranslation,
                         "both shows both")
            await expect(TranslationColumnMode.sourceOnly.showsSource
                            && !TranslationColumnMode.sourceOnly.showsTranslation,
                         "sourceOnly hides the translation")
            await expect(!TranslationColumnMode.translationOnly.showsSource
                            && TranslationColumnMode.translationOnly.showsTranslation,
                         "translationOnly hides the source")

            // Toggling a visible language off leaves the other one showing.
            await expect(TranslationColumnMode.both.toggling(source: true) == .translationOnly,
                         "hiding the source from both leaves the translation")
            await expect(TranslationColumnMode.both.toggling(source: false) == .sourceOnly,
                         "hiding the translation from both leaves the source")

            // Toggling the *last* visible language brings the other one back
            // rather than emptying the lane — the control can't reach a state
            // where nothing is readable.
            await expect(TranslationColumnMode.translationOnly.toggling(source: true) == .both,
                         "re-enabling the hidden source restores both")
            await expect(TranslationColumnMode.sourceOnly.toggling(source: false) == .both,
                         "re-enabling the hidden translation restores both")
            await expect(TranslationColumnMode.translationOnly.toggling(source: false) == .both,
                         "switching off the only visible language never blanks the lane")
            await expect(TranslationColumnMode.sourceOnly.toggling(source: true) == .both,
                         "same in the other direction")

            // The divider is only meaningful with two real columns.
            let wide = TranslationDisplay(layout: .auto, columnMode: .both, sourceFraction: 0.45,
                                          sourceLabel: "EN", targetLabel: "PT")
            await expect(wide.showsDivider(forTextWidth: 680), "divider shows for two side-by-side columns")
            await expect(!wide.showsDivider(forTextWidth: 300), "no divider when auto resolves to stacked")
            var single = wide
            single.columnMode = .translationOnly
            await expect(!single.showsDivider(forTextWidth: 680), "no divider when only one language shows")
            var stacked = wide
            stacked.layout = .stacked
            await expect(!stacked.showsDivider(forTextWidth: 680), "no divider in stacked layout")

            await expect(OverlayView.languageChipLabel("pt-BR") == "PT", "chip label drops the region")
            await expect(OverlayView.languageChipLabel("en") == "EN", "bare language code works")
            await expect(OverlayView.languageChipLabel("") == "?", "empty identifier gets a placeholder")

            await expect(TranslationSupport.isSameLanguage("en-US", "en-GB"),
                         "same language, different region counts as same")
            await expect(!TranslationSupport.isSameLanguage("en-US", "pt-BR"),
                         "different languages are not the same")
            await expect(!TranslationSupport.isSameLanguage("", "pt-BR"),
                         "empty identifier is never a match")
        }
    }

    static func runTranslationBufferSuite() async {
        await suite("TranscriptBuffer translation attachment") {
            let buffer = TranscriptBuffer()
            let id = UUID()
            await buffer.apply(TranscriptUpdate(id: id, text: "We should ship Friday.", isFinal: true,
                                                channel: .system, timestamp: Date()))
            await buffer.setTranslation(id: id, "Devemos lançar na sexta.")
            var snap = await buffer.snapshot()
            await expect(snap.first?.translatedText == "Devemos lançar na sexta.",
                         "translation attaches to a finalized row")
            await expect(await buffer.translation(forID: id) == "Devemos lançar na sexta.",
                         "translation(forID:) resolves the row for persistence")

            // Volatile row, then a replacement hypothesis: the previous
            // translation must carry forward so the column never blanks.
            let volatileBuffer = TranscriptBuffer()
            let v1 = UUID()
            await volatileBuffer.apply(TranscriptUpdate(id: v1, text: "I don't", isFinal: false,
                                                        channel: .system, timestamp: Date()))
            await volatileBuffer.setTranslation(id: v1, "Eu não")
            let v2 = UUID()
            await volatileBuffer.apply(TranscriptUpdate(id: v2, text: "I don't think", isFinal: false,
                                                        channel: .system, timestamp: Date()))
            snap = await volatileBuffer.snapshot()
            await expect(snap.first?.translatedText == "Eu não",
                         "a replaced hypothesis keeps the previous translation instead of blanking")

            // Committing that hypothesis must likewise inherit it.
            await volatileBuffer.apply(TranscriptUpdate(id: v2, text: "I don't think", isFinal: true,
                                                        channel: .system, timestamp: Date()))
            snap = await volatileBuffer.snapshot()
            await expect(snap.first?.isFinal == true, "row committed")
            await expect(snap.first?.translatedText == "Eu não",
                         "committing inherits the hypothesis's translation")

            // Unknown ids are silently ignored rather than creating rows.
            let before = await volatileBuffer.snapshot().count
            await volatileBuffer.setTranslation(id: UUID(), "orphan")
            await expect(await volatileBuffer.snapshot().count == before,
                         "setTranslation never creates a row")

            // Empty translations are refused — an empty string would blank a
            // column that previously had good text.
            await volatileBuffer.setTranslation(id: v2, "   ")
            snap = await volatileBuffer.snapshot()
            await expect(snap.first?.translatedText == "Eu não",
                         "blank translation is ignored, not written")
        }
    }

    static func runTranslationQueueSuite() async {
        await suite("TranslationQueue scheduling") {
            // Finalized system line translates without waiting for a debounce.
            let fake = FakeTranslator()
            let sink = TranslationSink()
            let queue = TranslationQueue(provider: fake) { id, text in await sink.record(id, text) }
            let segment = finalSystemSegment("We should ship Friday.")
            await queue.ingest([segment])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(fake.calls == ["We should ship Friday."], "finalized line translates immediately")
            await expect(await sink.results[segment.id] == "<We should ship Friday.>",
                         "result is written back under the row's id")

            // Re-ingesting the same text must not re-translate.
            await queue.ingest([segment])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(fake.calls.count == 1, "unchanged text is not re-translated")

            // A roll-up rewrites a committed row's text — that must re-translate.
            var grown = segment
            grown.text = "We should ship Friday. Or Monday."
            await queue.ingest([grown])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(fake.calls.count == 2, "a rewritten committed row re-translates")
            await expect(fake.calls.last == "We should ship Friday. Or Monday.",
                         "re-translation uses the rewritten text")
            await queue.stop()
        }

        await suite("TranslationQueue channel and baseline gating") {
            let fake = FakeTranslator()
            let queue = TranslationQueue(provider: fake) { _, _ in }
            await queue.ingest([micSegment("This is me talking.")])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(fake.calls.isEmpty, "microphone lines are never translated")

            // Rows on screen when the feature is switched on stay untranslated,
            // so enabling mid-session can't fire a burst of ~150 calls.
            let existing = finalSystemSegment("Said before translation was on.")
            let queue2Fake = FakeTranslator()
            let queue2 = TranslationQueue(provider: queue2Fake) { _, _ in }
            await queue2.markBaseline([existing])
            await queue2.ingest([existing, finalSystemSegment("Said after.")])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(queue2Fake.calls == ["Said after."],
                         "baseline rows are skipped; only new lines translate")
            await queue.stop()
            await queue2.stop()
        }

        await suite("TranslationQueue debounce and degraded mode") {
            // A growing hypothesis under one id should collapse to a single
            // translation of the settled text, not one per revision.
            let fake = FakeTranslator()
            let queue = TranslationQueue(provider: fake) { _, _ in }
            let id = UUID()
            for text in ["I don't", "I don't think", "I don't think we should"] {
                await queue.ingest([volatileSystemSegment(id: id, text)])
                try? await Task.sleep(for: .milliseconds(40))
            }
            await expect(fake.calls.isEmpty, "nothing fires while the text is still changing")
            try? await Task.sleep(for: .milliseconds(600))
            await expect(fake.calls == ["I don't think we should"],
                         "debounce collapses a growing hypothesis to one call on the settled text")
            await queue.stop()

            // Tier-1 degradation: volatile rows are ignored entirely.
            let degradedFake = FakeTranslator()
            let degraded = TranslationQueue(provider: degradedFake) { _, _ in }
            await degraded.setMode(.finalsOnly)
            await degraded.ingest([volatileSystemSegment("still speaking")])
            try? await Task.sleep(for: .milliseconds(600))
            await expect(degradedFake.calls.isEmpty, "finalsOnly ignores in-progress rows")
            await degraded.ingest([finalSystemSegment("done speaking")])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(degradedFake.calls == ["done speaking"],
                         "finalsOnly still translates committed rows")
            await degraded.stop()

            // After stop(), late ingests are inert — no work on a torn-down session.
            let stoppedFake = FakeTranslator()
            let stopped = TranslationQueue(provider: stoppedFake) { _, _ in }
            await stopped.stop()
            await stopped.ingest([finalSystemSegment("too late")])
            try? await Task.sleep(for: translationSettleDelay)
            await expect(stoppedFake.calls.isEmpty, "a stopped queue does no work")
        }
    }

    static func runTranslationPersistenceSuite() async {
        await suite("SessionStore translation round-trip") {
            let markdown = """
            # Transcript

            **Other** [10:00:01] We should ship on Friday.
            > pt-BR — Devemos lançar na sexta-feira.

            **Me** [10:00:09] I disagree.

            **Other** [10:00:12] Why?
            > pt-BR — Por quê?
            """

            let segments = SessionStore.parseTranscriptMarkdown(markdown)
            await expect(segments.count == 3, "three speaker lines parse, translations don't add rows")
            await expect(segments.first?.text == "We should ship on Friday.", "source text preserved")
            await expect(segments.first?.translatedText == "Devemos lançar na sexta-feira.",
                         "translation attaches to the line above it")
            await expect(segments[1].translatedText == nil,
                         "an untranslated line keeps a nil translation")
            await expect(segments[2].translatedText == "Por quê?", "later translations attach correctly")

            // The resume path must not feed both languages to the model.
            let stripped = SessionStore.strippingTranslations(markdown)
            await expect(!stripped.contains("Devemos lançar"), "translations are stripped for AI context")
            await expect(!stripped.contains("Por quê?"), "every translation line is stripped")
            await expect(stripped.contains("We should ship on Friday."), "source lines survive stripping")
            await expect(stripped.contains("I disagree."), "untranslated lines survive stripping")

            // A file written by an older build (no translation lines) still loads.
            let legacy = """
            # Transcript

            **Other** [10:00:01] We should ship on Friday.

            **Me** [10:00:09] I disagree.
            """
            let legacySegments = SessionStore.parseTranscriptMarkdown(legacy)
            await expect(legacySegments.count == 2, "pre-translation transcripts parse unchanged")
            await expect(legacySegments.allSatisfy { $0.translatedText == nil },
                         "no translations invented for legacy files")
        }
    }

}
