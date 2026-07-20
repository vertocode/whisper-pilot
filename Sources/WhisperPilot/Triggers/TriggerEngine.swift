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
}

private let triggerLog = Logger(subsystem: "com.whisperpilot.app", category: "Trigger")

/// Decides when to actually call the LLM:
/// - score must clear `threshold`
/// - we must have observed a VAD-defined pause on the *same* channel after the question
/// - cooldown since last fire must be respected (global — back-to-back fires from
///   different channels still cool down together so the assistant doesn't pile on)
/// - duplicate questions (same text within the cooldown window) are suppressed
///
/// State is tracked per `AudioChannel` so a question from "Me" and a question
/// from "Other" can both be in flight simultaneously without clobbering each
/// other's pending state.
actor TriggerEngine {
    nonisolated let events: AsyncStream<TriggerEvent>
    nonisolated private let continuation: AsyncStream<TriggerEvent>.Continuation

    private let detector = QuestionDetector()
    private let threshold: Double = 0.6
    private let cooldown: TimeInterval = 8
    /// How long the channel must be quiet after a candidate question before we
    /// fire. Kept short (was 0.7) because the prior latency was dominated by
    /// SFSpeech taking many seconds to finalize, not by the pause check — once
    /// we accept non-final segments, the pause is the only thing holding us
    /// back, and a longer pause just delays the response without filtering out
    /// anything meaningful.
    private let pauseRequirement: TimeInterval = 0.35

    private var lastFireAt: Date = .distantPast
    private var lastFiredText: String = ""

    private var pendingCandidate: [AudioChannel: TranscriptSegment] = [:]
    private var lastSpeechEndedAt: [AudioChannel: Date] = [:]
    /// Re-arm timers, one per channel. When `attemptFire` holds because the pause
    /// or cooldown hasn't elapsed *yet*, nothing external is guaranteed to call it
    /// again (the recognizer may already have delivered its last hypothesis), so a
    /// held candidate would otherwise be dropped silently. The timer retries at the
    /// exact moment the gate opens.
    private var retryTasks: [AudioChannel: Task<Void, Never>] = [:]

    init() {
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
            pendingCandidate[channel] = nil
            retryTasks[channel]?.cancel()
            retryTasks[channel] = nil
        case .speechEnded(let channel, let at, _, _):
            lastSpeechEndedAt[channel] = at
            attemptFire(on: channel)
        }
    }

    func consider(segment: TranscriptSegment) {
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
        guard score >= threshold else { return }
        triggerLog.info("Pending candidate (channel=\(String(describing: segment.channel), privacy: .public), score=\(score, privacy: .public)): \"\(segment.text, privacy: .private)\"")
        pendingCandidate[segment.channel] = segment
        attemptFire(on: segment.channel)
    }

    private func attemptFire(on channel: AudioChannel) {
        guard let candidate = pendingCandidate[channel] else { return }
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
        guard sinceLast >= cooldown else {
            triggerLog.info("Holding fire — cooldown (\(sinceLast, privacy: .public)s < \(self.cooldown, privacy: .public)s)")
            scheduleRetry(on: channel, after: cooldown - sinceLast)
            return
        }

        let normalized = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == lastFiredText {
            triggerLog.info("Holding fire — duplicate of previous question")
            return
        }

        lastFireAt = now
        lastFiredText = normalized
        pendingCandidate[channel] = nil
        retryTasks[channel]?.cancel()
        retryTasks[channel] = nil

        let event = TriggerEvent(
            text: candidate.text,
            score: detector.score(candidate),
            firedAt: now,
            channel: channel
        )
        triggerLog.info("🔔 FIRE (\(String(describing: channel), privacy: .public)): \"\(candidate.text, privacy: .private)\" (score=\(event.score, privacy: .public))")
        continuation.yield(event)
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
