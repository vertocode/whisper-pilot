import Foundation
import OSLog

struct TriggerEvent: Sendable {
    let text: String
    let score: Double
    let firedAt: Date
    /// Which side spoke the question — `.system` (Other) or `.microphone` (Me).
    /// Lets the UI / prompt builder differentiate, and lets the coordinator
    /// double-check the per-channel auto-detect toggle before actually calling
    /// the AI (defense in depth against settings flipping mid-stream).
    let channel: AudioChannel
    /// The text only *might* be a question, so the AI must confirm it before answering.
    let needsCheck: Bool
    /// Set when this is a longer version of a question that fired a moment ago (the
    /// speaker kept talking after a short pause). Holds the earlier text, so its
    /// answer can be replaced instead of showing two answers to one question.
    var supersedes: String? = nil
}

private let triggerLog = Logger(subsystem: "com.whisperpilot.app", category: "Trigger")

/// Decides when to actually call the LLM:
/// - score must clear `threshold`
/// - we must have observed a VAD-defined pause on the *same* channel after the question
/// - cooldown since last fire must be respected (global — back-to-back fires from
///   different channels still cool down together so the assistant doesn't pile on)
/// - a question that already fired, or a piece of one, does not fire again
///
/// State is tracked per `AudioChannel` so a question from "Me" and a question
/// from "Other" can both be in flight simultaneously without clobbering each
/// other's pending state.
actor TriggerEngine {
    nonisolated let events: AsyncStream<TriggerEvent>
    nonisolated private let continuation: AsyncStream<TriggerEvent>.Continuation

    private let detector = QuestionDetector()
    private let threshold: Double = 0.6
    private let cooldown: TimeInterval
    /// How long the start of a question waits for the rest of it. Interviewers often
    /// pause mid-question, so the recognizer splits it across two lines and the second
    /// line ("online store 2.0 themes in production?") has no question word of its own.
    private let carryWindow: TimeInterval = 8
    /// How long the channel must be quiet after a candidate question before we
    /// fire. Kept short (was 0.7) because the prior latency was dominated by
    /// SFSpeech taking many seconds to finalize, not by the pause check — once
    /// we accept non-final segments, the pause is the only thing holding us
    /// back, and a longer pause just delays the response without filtering out
    /// anything meaningful.
    private let pauseRequirement: TimeInterval = 0.35

    /// Questions fired recently. The same line reaches the engine many times (every
    /// partial, every final, every pause), so one remembered text is not enough.
    /// `replaced` is set once a fire has already replaced an earlier, cut-off one,
    /// so a speaker who keeps talking can't make the same answer change again and again.
    private var recentFires: [(text: String, at: Date, replaced: Bool)] = []
    /// A cut-off question is only finished by a few more words. A longer run of
    /// words is the speaker moving on, not the end of the question.
    private let maxFinishingWords = 15
    private let recentFireMemory: TimeInterval = 90
    /// A longer version of a fired question within this window replaces its answer.
    private let supersedeWindow: TimeInterval = 20

    private var lastFireAt: Date = .distantPast

    private var pendingCandidate: [AudioChannel: TranscriptSegment] = [:]
    private var pendingNeedsCheck: [AudioChannel: Bool] = [:]
    private var carriedStart: [AudioChannel: TranscriptSegment] = [:]
    /// Once a line was joined to the start of its question, every later version of
    /// that line (the recognizer keeps growing it) gets the same start.
    private var joinedStart: [AudioChannel: (segmentID: UUID, start: TranscriptSegment)] = [:]
    private var lastSpeechEndedAt: [AudioChannel: Date] = [:]
    /// Without this, a partial like "Tell me about your" that scores high could
    /// fire mid-sentence, using the pause from the speaker's *previous* utterance.
    private var isSpeaking: [AudioChannel: Bool] = [:]
    /// Re-arm timers, one per channel. When `attemptFire` holds because the pause
    /// or cooldown hasn't elapsed *yet*, nothing external is guaranteed to call it
    /// again (the recognizer may already have delivered its last hypothesis), so a
    /// held candidate would otherwise be dropped silently. The timer retries at the
    /// exact moment the gate opens.
    private var retryTasks: [AudioChannel: Task<Void, Never>] = [:]

    init(cooldown: TimeInterval = 3) {
        self.cooldown = cooldown
        var capturedContinuation: AsyncStream<TriggerEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func absorb(_ event: VoiceActivityEvent) {
        switch event {
        case .speechStarted(let channel, _):
            // Speaker resumed — kill any pending candidate on that channel so we
            // don't fire mid-utterance.
            dropCandidate(on: channel)
            isSpeaking[channel] = true
        case .speechEnded(let channel, let at, _, _):
            isSpeaking[channel] = false
            lastSpeechEndedAt[channel] = at
            attemptFire(on: channel)
        }
    }

    func consider(segment rawSegment: TranscriptSegment) {
        let segment = joiningCarriedStart(rawSegment)
        // Accept non-final segments. SFSpeech's `.auto` boundary mode often holds
        // back finalization for tens of seconds; by then the speaker has long moved
        // on and our "real-time" copilot has missed the moment. Partials are stable
        // enough at speech-end (VAD pause) to score on. attemptFire still gates on
        // the post-utterance pause, so the partial we react to is whatever the
        // recognizer's best hypothesis was when the speaker actually stopped.
        let score = detector.score(segment)
        // Spoken content is logged `.private` — the unified log is captured in
        // sysdiagnoses and readable in Console.app, and leaking meeting audio
        // transcripts there contradicts the app's local-privacy promise.
        triggerLog.debug("Considered segment (channel=\(String(describing: segment.channel), privacy: .public), final=\(segment.isFinal, privacy: .public), score=\(score, privacy: .public)): \"\(segment.text, privacy: .private)\"")
        let needsCheck = score < threshold
        guard !needsCheck || detector.mightBeQuestion(segment) else {
            // A newer hypothesis for this channel no longer reads as a question
            // (e.g. "tell me about your..." became "...actually, never mind"), so
            // the older candidate must not fire at the next pause.
            if pendingCandidate[segment.channel]?.id == segment.id {
                dropCandidate(on: segment.channel)
            }
            return
        }
        if joinedStart[segment.channel]?.segmentID != rawSegment.id {
            carriedStart[segment.channel] = rawSegment
        }
        pendingNeedsCheck[segment.channel] = needsCheck
        triggerLog.info("Pending candidate (channel=\(String(describing: segment.channel), privacy: .public), score=\(score, privacy: .public)): \"\(segment.text, privacy: .private)\"")
        pendingCandidate[segment.channel] = segment
        attemptFire(on: segment.channel)
    }

    /// A line that isn't a question alone may be the end of one that started on the
    /// previous line. Joins the two so the detector and the AI see the whole question.
    private func joiningCarriedStart(_ segment: TranscriptSegment) -> TranscriptSegment {
        func joined(_ start: TranscriptSegment) -> TranscriptSegment {
            var joined = segment
            joined.text = start.text + " " + segment.text
            joined.startedAt = start.startedAt
            return joined
        }
        if let earlier = joinedStart[segment.channel], earlier.segmentID == segment.id {
            // The line grew into a question of its own ("? Do you" became
            // "? Do you have the dates"), so it no longer needs the start.
            guard detector.score(segment) < threshold else {
                joinedStart[segment.channel] = nil
                return segment
            }
            return joined(earlier.start)
        }
        // The recognizer capitalizes a new sentence, so only a line that starts in
        // lowercase ("online store themes...") continues the one before it. One that
        // starts with "? Thank you" or "Great." is the speaker moving on.
        guard let first = segment.text.trimmingCharacters(in: .whitespaces).first,
              first.isLowercase,
              let start = carriedStart[segment.channel], start.id != segment.id,
              segment.startedAt.timeIntervalSince(start.updatedAt) < carryWindow,
              detector.score(segment) < threshold, !detector.mightBeQuestion(segment)
        else { return segment }
        let candidate = joined(start)
        guard detector.score(candidate) >= threshold || detector.mightBeQuestion(candidate) else { return segment }
        carriedStart[segment.channel] = nil
        joinedStart[segment.channel] = (segment.id, start)
        return candidate
    }

    private func attemptFire(on channel: AudioChannel) {
        guard let candidate = pendingCandidate[channel] else { return }
        // speechEnded calls back in here, so a held candidate is not lost.
        guard isSpeaking[channel] != true else { return }
        guard let endedAt = lastSpeechEndedAt[channel] else {
            triggerLog.debug("Holding fire — no speech-ended observed on \(String(describing: channel), privacy: .public) yet")
            return
        }

        let now = Date()
        let elapsedSincePause = now.timeIntervalSince(endedAt)
        guard elapsedSincePause >= pauseRequirement else {
            triggerLog.debug("Holding fire — pause too short (\(elapsedSincePause, privacy: .public)s < \(self.pauseRequirement, privacy: .public)s)")
            scheduleRetry(on: channel, after: pauseRequirement - elapsedSincePause)
            return
        }
        let sinceLast = now.timeIntervalSince(lastFireAt)
        let needsCheck = pendingNeedsCheck[channel] ?? false
        guard sinceLast >= cooldown else {
            triggerLog.info("Holding fire — cooldown (\(sinceLast, privacy: .public)s < \(self.cooldown, privacy: .public)s)")
            scheduleRetry(on: channel, after: cooldown - sinceLast)
            return
        }

        recentFires.removeAll { now.timeIntervalSince($0.at) > recentFireMemory }
        var text = candidate.text
        var supersedes: String?
        var replaced = false
        for fired in recentFires.reversed() {
            guard let kept = TranscriptDedup.merged(previous: fired.text, incoming: candidate.text) else { continue }
            let isLonger = kept == candidate.text
                && TranscriptDedup.normalized(candidate.text) != TranscriptDedup.normalized(fired.text)
            guard isLonger else {
                triggerLog.info("Holding fire — already fired this question")
                dropCandidate(on: channel)
                return
            }
            // The line grew past the fired question. When the fired text was cut off
            // mid-sentence, the words up to the next sentence end finish it ("...apps"
            // + "in production?"), and the full question replaces the first answer,
            // but only once. Anything after that only fires if it holds a new
            // question of its own.
            let (added, afterSentenceEnd) = Self.wordsAfter(fired.text, in: candidate.text)
            let firedWasComplete = afterSentenceEnd
                || (fired.text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false)
            let (finishing, rest) = firedWasComplete ? ("", added) : Self.splitAtFirstSentenceEnd(added)
            let finishingWords = finishing.split(whereSeparator: \.isWhitespace).count
            var restSegment = candidate
            restSegment.text = rest
            if !finishing.isEmpty, !fired.replaced, finishingWords <= maxFinishingWords,
               now.timeIntervalSince(fired.at) <= supersedeWindow {
                text = fired.text + " " + finishing
                supersedes = fired.text
                replaced = true
            } else if !rest.isEmpty, detector.score(restSegment) >= threshold {
                text = rest
            } else {
                triggerLog.info("Holding fire — line grew past a question that already fired")
                dropCandidate(on: channel)
                return
            }
            break
        }

        // A line the AI may still reject must not start the cooldown, or it
        // could block a real question asked right after it.
        if !needsCheck { lastFireAt = now }
        recentFires.append((candidate.text, now, replaced))
        dropCandidate(on: channel)

        let event = TriggerEvent(
            text: text,
            score: detector.score(candidate),
            firedAt: now,
            channel: channel,
            needsCheck: needsCheck,
            supersedes: supersedes
        )
        triggerLog.info("🔔 FIRE (\(String(describing: channel), privacy: .public)): \"\(candidate.text, privacy: .private)\" (score=\(event.score, privacy: .public))")
        continuation.yield(event)
    }

    /// The words of `longer` that come after the last word of `shorter`, keeping
    /// their original spelling, and whether a sentence ends right before them
    /// ("...in production? Okay, and..."). Empty when `shorter` is not in `longer`.
    static func wordsAfter(_ shorter: String, in longer: String) -> (text: String, afterSentenceEnd: Bool) {
        let short: [String] = TranscriptDedup.normalized(shorter).split(separator: " ").map(String.init)
        let longWords: [String] = longer.split(whereSeparator: \.isWhitespace).map(String.init)
        let long: [String] = longWords.map { TranscriptDedup.normalized($0) }
        guard !short.isEmpty, short.count < long.count else { return ("", false) }
        var start = long.count - short.count
        while start >= 0 {
            if Array(long[start..<(start + short.count)]) == short {
                let end = start + short.count
                let closed = longWords[end - 1].last.map { ".?!".contains($0) } ?? false
                return (longWords[end...].joined(separator: " "), closed)
            }
            start -= 1
        }
        return ("", false)
    }

    /// Splits after the first word that ends a sentence. Without one, everything is
    /// the first part: the sentence is still going.
    static func splitAtFirstSentenceEnd(_ text: String) -> (String, String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let end = words.firstIndex(where: { $0.last.map { ".?!".contains($0) } ?? false }) else {
            return (text, "")
        }
        return (words[...end].joined(separator: " "), words[(end + 1)...].joined(separator: " "))
    }

    private func dropCandidate(on channel: AudioChannel) {
        pendingCandidate[channel] = nil
        pendingNeedsCheck[channel] = nil
        retryTasks[channel]?.cancel()
        retryTasks[channel] = nil
    }

    /// Retry `attemptFire` once the remaining gate time has elapsed. Replaces any
    /// previously scheduled retry for the channel (the newest hold knows the most
    /// current remaining delay). The small epsilon guards against re-holding on
    /// timer jitter right at the boundary.
    private func scheduleRetry(on channel: AudioChannel, after delay: TimeInterval) {
        retryTasks[channel]?.cancel()
        retryTasks[channel] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.attemptFire(on: channel)
        }
    }

    deinit {
        for task in retryTasks.values { task.cancel() }
        continuation.finish()
    }
}
