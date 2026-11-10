import Foundation

/// Lets an action through at most once per `interval`. Used to keep fast-moving
/// readouts (CPU, counters) from redrawing the overlay on every tick.
struct MinIntervalGate {
    let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    mutating func allow(at now: ContinuousClock.Instant) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }

    /// How long until the next action may pass. Zero when it may pass now.
    func remaining(at now: ContinuousClock.Instant) -> Duration {
        guard let last else { return .zero }
        return max(.zero, interval - (now - last))
    }

    /// Starts a new interval for an action that had to go through regardless.
    mutating func record(at now: ContinuousClock.Instant) {
        last = now
    }

    mutating func reset() {
        last = nil
    }
}

/// Limits redraws to one per interval and remembers a change that had to wait,
/// so its publish still happens once the interval is over.
struct TrailingPublishThrottle {
    private var gate: MinIntervalGate
    private var isPending = false

    init(interval: Duration) {
        gate = MinIntervalGate(interval: interval)
    }

    func isDue(at now: ContinuousClock.Instant) -> Bool {
        gate.remaining(at: now) == .zero
    }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        gate.remaining(at: now)
    }

    /// False when a publish is already waiting and will pick this change up.
    mutating func requestPublish() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    /// Claims the waiting publish. The interval starts here, before the caller
    /// reads the data, so a change landing during that read waits its turn
    /// instead of starting a second read that could finish out of order.
    mutating func takePending(at now: ContinuousClock.Instant) -> Bool {
        guard isPending else { return false }
        isPending = false
        gate.record(at: now)
        return true
    }

    mutating func recordPublish(at now: ContinuousClock.Instant) {
        gate.record(at: now)
    }

    mutating func reset() {
        isPending = false
        gate.reset()
    }
}
