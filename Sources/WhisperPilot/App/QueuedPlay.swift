/// Decides what a press of the Play/Stop button means, and remembers one Play made
/// while a cancelled startup is still finishing. That startup's model load can't be
/// interrupted, and a second load beside it could reach the app's memory limit, so
/// the new start has to wait for the old one to return.
struct QueuedPlay {
    enum Action: Equatable {
        case start, stop, queueStart, cancelQueuedStart, ignore
    }

    private(set) var isQueued = false

    mutating func press(isRunning: Bool, isStartingUp: Bool, isStartupLive: Bool, isStopping: Bool) -> Action {
        // The button still shows Stop during teardown, so this press can't mean Play.
        if isStopping { return .ignore }
        if isQueued {
            isQueued = false
            return .cancelQueuedStart
        }
        if isRunning || isStartupLive { return .stop }
        guard isStartingUp else { return .start }
        isQueued = true
        return .queueStart
    }

    mutating func clear() {
        isQueued = false
    }

    mutating func take() -> Bool {
        defer { isQueued = false }
        return isQueued
    }
}
