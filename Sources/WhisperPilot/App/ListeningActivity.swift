import Foundation

/// Tells macOS the app is doing real work while it listens, so App Nap does not
/// slow its timers and network calls when a meeting window covers it.
final class ListeningActivity {
    private var token: NSObjectProtocol?

    var isActive: Bool { token != nil }

    func begin() {
        guard token == nil else { return }
        // Not `.userInitiated`: that one also keeps the whole Mac from sleeping.
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Whisper Pilot is transcribing a live conversation"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit { end() }
}

/// What to do after the Mac wakes while a session is running.
enum WakeRecovery {
    /// Audio is expected to keep arriving. If no new frame showed up during the
    /// grace period after wake, the capture died with the sleep and needs a restart.
    static func needsRestart(framesBefore: Int, framesAfter: Int) -> Bool {
        framesAfter <= framesBefore
    }

    static let gracePeriodSeconds: UInt64 = 5
}
