import AVFoundation
import Foundation

/// Records audio buffers silently discarded by a bounded `AsyncStream` (the
/// `.bufferingNewest` policy evicts the oldest element when a consumer falls
/// behind). Each drop is a hole in the transcript, so it must be visible in the
/// log. Only the drop path does any work: the hot path just inspects the
/// `yield` result it already gets back.
final class AudioDropMonitor: @unchecked Sendable {
    static let shared = AudioDropMonitor()

    private struct Tally {
        var buffers = 0
        var seconds: Double = 0
        var lastLog: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var tallies: [String: Tally] = [:]
    /// Summaries are rate-limited per stage so a long stall can't flood the log.
    private let logInterval: Duration = .seconds(5)

    /// Call when `continuation.yield(...)` returned `.dropped(...)`.
    /// `buffer` is the evicted element's audio, used to size the hole in seconds.
    func recordDrop(stage: String, buffer: AVAudioPCMBuffer?) {
        let seconds: Double
        if let buffer, buffer.format.sampleRate > 0 {
            seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        } else {
            seconds = 0
        }
        let now = ContinuousClock.now
        var message: String?
        lock.lock()
        var tally = tallies[stage, default: Tally()]
        tally.buffers += 1
        tally.seconds += seconds
        if tally.lastLog.map({ now - $0 >= logInterval }) ?? true {
            message = "Audio drop: \(stage) consumer fell behind — discarded \(tally.buffers) buffer(s) ≈ \(String(format: "%.2f", tally.seconds)) s of audio (transcript gap)"
            tally.buffers = 0
            tally.seconds = 0
            tally.lastLog = now
        }
        tallies[stage] = tally
        lock.unlock()
        if let message { wpWarn(message) }
    }

    /// Unlogged remainder at session end, so short final bursts aren't lost.
    func flushSummary() {
        lock.lock()
        let pending = tallies.filter { $0.value.buffers > 0 }
        tallies.removeAll()
        lock.unlock()
        for (stage, tally) in pending {
            wpWarn("Audio drop: \(stage) discarded \(tally.buffers) more buffer(s) ≈ \(String(format: "%.2f", tally.seconds)) s of audio")
        }
    }
}

extension AsyncStream.Continuation where Element == AudioFrame {
    /// `yield` that reports evictions to `AudioDropMonitor`.
    func yieldTracked(_ frame: AudioFrame, stage: String) {
        if case .dropped(let evicted) = yield(frame) {
            AudioDropMonitor.shared.recordDrop(stage: "\(stage).\(evicted.channel)", buffer: evicted.buffer)
        }
    }
}
