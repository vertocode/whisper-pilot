import Foundation
import OSLog

/// Fired when the user spoke the wake word followed by a command on the
/// microphone channel and then paused. `command` is the text after the wake
/// word ("pilot, open chrome" → "open chrome").
struct WakeCommandEvent: Sendable {
    let command: String
    let firedAt: Date
}

private let wakeLog = Logger(subsystem: "com.whisperpilot.app", category: "WakeWord")

/// Detects spoken wake-word commands on the microphone channel. Mirrors
/// `TriggerEngine`'s shape — partial hypotheses keep the pending command fresh,
/// and the fire is gated on a VAD-observed pause so we react to what the user
/// actually finished saying, not a mid-utterance fragment.
///
/// Mic-only by design: the wake word is the *user* addressing the assistant.
/// Reacting to "pilot" on the system-audio side would let the other meeting
/// participant drive the user's machine.
actor WakeWordEngine {
    nonisolated let events: AsyncStream<WakeCommandEvent>
    nonisolated private let continuation: AsyncStream<WakeCommandEvent>.Continuation

    /// Deliberately much longer than TriggerEngine's 0.35s. A command is
    /// dictated word by word ("open … Safari") with natural micro-pauses, and
    /// firing on the first one captures half the command — observed in the
    /// field as the AI receiving "open" and asking "open what?". 1.5s means
    /// "the user actually finished talking".
    private let pauseRequirement: TimeInterval = 1.5
    /// Short cooldown — back-to-back commands are a legitimate use ("pilot open
    /// chrome" … "pilot search swift docs"), unlike auto-detected questions.
    private let cooldown: TimeInterval = 3

    private var lastFireAt: Date = .distantPast
    private var pendingCommand: (segmentID: UUID, command: String)?
    private var lastSpeechEndedAt: Date?
    /// Fires `attemptFire` once the pause window elapses. TriggerEngine gets
    /// away without one because its 0.35s gate is cleared by the recognizer's
    /// own trailing updates; at 1.5s there may be no further event to piggyback
    /// on, so we schedule our own re-check. Cancelled if speech resumes.
    private var scheduledFire: Task<Void, Never>?
    /// Segment ids that already fired. A partial hypothesis can keep growing
    /// after the fire ("open chrome" → "open chrome please"); without this the
    /// trailing growth would re-fire the same utterance.
    private var firedSegments: Set<UUID> = []

    init() {
        var capturedContinuation: AsyncStream<WakeCommandEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func absorb(_ event: VoiceActivityEvent) {
        switch event {
        case .speechStarted(let channel, _):
            // User resumed talking — don't fire on the half-spoken command;
            // the growing hypothesis will re-arm via `consider`.
            if channel == .microphone {
                pendingCommand = nil
                scheduledFire?.cancel()
                scheduledFire = nil
            }
        case .speechEnded(let channel, let at, _, _):
            if channel == .microphone {
                lastSpeechEndedAt = at
                attemptFire()
                scheduleFireAfterPause()
            }
        }
    }

    /// Re-check once the pause window has fully elapsed. The +0.1s slack keeps
    /// the wall-clock comparison inside `attemptFire` from racing the sleep.
    private func scheduleFireAfterPause() {
        guard pendingCommand != nil else { return }
        scheduledFire?.cancel()
        let delay = pauseRequirement + 0.1
        scheduledFire = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.attemptFire()
        }
    }

    func consider(segment: TranscriptSegment, wakeWord: String) {
        guard segment.channel == .microphone else { return }
        guard !firedSegments.contains(segment.id) else { return }
        guard let command = Self.extractCommand(from: segment.text, wakeWord: wakeWord) else { return }
        wakeLog.info("Pending wake command: \"\(command, privacy: .public)\"")
        pendingCommand = (segment.id, command)
        attemptFire()
    }

    private func attemptFire() {
        guard let pending = pendingCommand else { return }
        guard let endedAt = lastSpeechEndedAt else { return }

        let now = Date()
        guard now.timeIntervalSince(endedAt) >= pauseRequirement else { return }
        guard now.timeIntervalSince(lastFireAt) >= cooldown else {
            wakeLog.info("Holding wake command — cooldown")
            return
        }

        lastFireAt = now
        pendingCommand = nil
        firedSegments.insert(pending.segmentID)

        let event = WakeCommandEvent(command: pending.command, firedAt: now)
        wakeLog.info("🎙️ WAKE FIRE: \"\(pending.command, privacy: .public)\"")
        print("[WP][WakeWord] 🎙️ FIRE: \"\(pending.command)\"")
        continuation.yield(event)
    }

    /// Returns the command portion of `text` — everything after the first
    /// whole-word, case-insensitive occurrence of `wakeWord` — or nil when the
    /// wake word is absent or nothing follows it. Leading/trailing punctuation
    /// around the command is stripped ("pilot, open chrome." → "open chrome").
    static func extractCommand(from text: String, wakeWord: String) -> String? {
        let word = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let after = ns.substring(from: match.range.location + match.range.length)
        let trimSet = CharacterSet(charactersIn: ",.!?:;—–-").union(.whitespacesAndNewlines)
        let command = after.trimmingCharacters(in: trimSet)
        return command.isEmpty ? nil : command
    }

    deinit {
        continuation.finish()
    }
}
