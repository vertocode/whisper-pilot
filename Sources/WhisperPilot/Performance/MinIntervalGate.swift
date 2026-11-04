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

    mutating func reset() {
        last = nil
    }
}
