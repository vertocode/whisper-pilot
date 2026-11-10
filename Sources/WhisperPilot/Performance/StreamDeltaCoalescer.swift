import Foundation

/// Joins streamed reply text so the overlay redraws at most once per `interval`.
/// The first delta passes straight through, so a reply starts without delay.
struct StreamDeltaCoalescer {
    let interval: Duration
    private var lastFlush: ContinuousClock.Instant?
    private var pending = ""

    init(interval: Duration) {
        self.interval = interval
    }

    /// Returns the text to show now, or nil when it is held for a later flush.
    mutating func add(_ delta: String, at now: ContinuousClock.Instant) -> String? {
        pending += delta
        return remainingWait(at: now) == .zero ? drain(at: now) : nil
    }

    func remainingWait(at now: ContinuousClock.Instant) -> Duration {
        guard let lastFlush else { return .zero }
        return max(.zero, lastFlush + interval - now)
    }

    mutating func drain(at now: ContinuousClock.Instant) -> String? {
        guard !pending.isEmpty else { return nil }
        lastFlush = now
        defer { pending = "" }
        return pending
    }
}

/// Runs a `StreamDeltaCoalescer` on the main actor. The timer covers a pause in
/// the stream: without it, held text would stay hidden until the next delta.
@MainActor
final class StreamDeltaPacer {
    private var coalescer: StreamDeltaCoalescer
    private let apply: (String) -> Void
    private var timer: Task<Void, Never>?

    init(interval: Duration, apply: @escaping (String) -> Void) {
        self.coalescer = StreamDeltaCoalescer(interval: interval)
        self.apply = apply
    }

    func add(_ delta: String) {
        let now = ContinuousClock.now
        if let text = coalescer.add(delta, at: now) {
            timer?.cancel()
            timer = nil
            apply(text)
        } else if timer == nil {
            let wait = coalescer.remainingWait(at: now)
            timer = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        timer?.cancel()
        timer = nil
        if let text = coalescer.drain(at: .now) { apply(text) }
    }
}
