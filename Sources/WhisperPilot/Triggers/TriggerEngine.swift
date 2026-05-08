import Foundation
import OSLog

struct TriggerEvent: Sendable {
    let text: String
    let score: Double
    let firedAt: Date
}

private let triggerLog = Logger(subsystem: "com.whisperpilot.app", category: "Trigger")

/// Decides when to actually call the LLM:
/// - score must clear `threshold`
/// - we must have observed a VAD-defined pause on the system channel after the question
/// - cooldown since last fire must be respected
/// - duplicate questions (same text within the cooldown window) are suppressed
actor TriggerEngine {
    nonisolated let events: AsyncStream<TriggerEvent>
    nonisolated private let continuation: AsyncStream<TriggerEvent>.Continuation

    private let detector = QuestionDetector()
    private let threshold: Double = 0.6
    private let cooldown: TimeInterval = 8
    private let pauseRequirement: TimeInterval = 0.7

    private var lastFireAt: Date = .distantPast
    private var lastFiredText: String = ""

    private var pendingCandidate: TranscriptSegment?
    private var lastSystemSpeechEndedAt: Date?

    init() {
        var capturedContinuation: AsyncStream<TriggerEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func absorb(_ event: VoiceActivityEvent) {
        switch event {
        case .speechStarted:
            // user/other resumed talking — kill any pending candidate so we don't fire mid-conversation
            if case .speechStarted(let channel, _) = event, channel == .system {
                pendingCandidate = nil
            }
        case .speechEnded(let channel, let at, _, _) where channel == .system:
            lastSystemSpeechEndedAt = at
            attemptFire()
        case .speechEnded:
            break
        }
    }

    func consider(segment: TranscriptSegment) {
        guard segment.channel == .system, segment.isFinal else { return }
        let score = detector.score(segment)
        triggerLog.debug("Considered segment (score=\(score, privacy: .public)): \"\(segment.text, privacy: .public)\"")
        guard score >= threshold else { return }
        triggerLog.info("Pending candidate (score=\(score, privacy: .public)): \"\(segment.text, privacy: .public)\"")
        pendingCandidate = segment
        attemptFire()
    }

    private func attemptFire() {
        guard let candidate = pendingCandidate else { return }
        guard let endedAt = lastSystemSpeechEndedAt else {
            triggerLog.debug("Holding fire — no system-speech end observed yet")
            return
        }

        let now = Date()
        let elapsedSincePause = now.timeIntervalSince(endedAt)
        guard elapsedSincePause >= pauseRequirement else {
            triggerLog.debug("Holding fire — pause too short (\(elapsedSincePause, privacy: .public)s < \(self.pauseRequirement, privacy: .public)s)")
            return
        }
        let sinceLast = now.timeIntervalSince(lastFireAt)
        guard sinceLast >= cooldown else {
            triggerLog.info("Holding fire — cooldown (\(sinceLast, privacy: .public)s < \(self.cooldown, privacy: .public)s)")
            return
        }

        let normalized = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == lastFiredText {
            triggerLog.info("Holding fire — duplicate of previous question")
            return
        }

        lastFireAt = now
        lastFiredText = normalized
        pendingCandidate = nil

        let event = TriggerEvent(
            text: candidate.text,
            score: detector.score(candidate),
            firedAt: now
        )
        triggerLog.info("🔔 FIRE: \"\(candidate.text, privacy: .public)\" (score=\(event.score, privacy: .public))")
        print("[WP][Trigger] 🔔 FIRE: \"\(candidate.text)\" (score=\(event.score))")
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}
