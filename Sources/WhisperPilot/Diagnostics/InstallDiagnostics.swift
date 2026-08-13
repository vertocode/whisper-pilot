import Foundation

/// Checks for install-location problems that look like app bugs but aren't.
///
/// Right now that means one thing: **App Translocation**. When a downloaded app
/// still carries `com.apple.quarantine` and wasn't moved in Finder, Gatekeeper
/// refuses to run it from where it sits and instead mounts a randomized
/// read-only copy at
///
///     /private/var/folders/…/AppTranslocation/<UUID>/d/WhisperPilot.app
///
/// The UUID is different on every launch. macOS's privacy database (TCC) keys
/// permission grants on the app's identity *and* path, so a translocated app
/// looks brand new each time it starts: Screen Recording and Microphone grants
/// never stick, and the user re-authorizes on every single launch.
///
/// There is no way for the app to fix this from the inside — the translocated
/// mount is read-only and the original location isn't reachable through public
/// API. What we *can* do is stop the user thinking the app is broken, name the
/// cause, and hand them the exact command.
///
/// Homebrew installs strip the quarantine attribute, so this only bites people
/// who dragged the app out of the `.dmg`.
enum InstallDiagnostics {
    /// Marker macOS puts in the path of every translocated bundle.
    private static let translocationMarker = "/AppTranslocation/"

    /// Where the running bundle actually lives. Split out so the check can be
    /// exercised with a synthetic path in tests.
    static var currentBundlePath: String { Bundle.main.bundlePath }

    static var isTranslocated: Bool {
        isTranslocatedPath(currentBundlePath)
    }

    static func isTranslocatedPath(_ path: String) -> Bool {
        path.contains(translocationMarker)
    }

    /// Canonical install location. Used in the remedy text; deliberately a
    /// constant rather than a guess at where the user put it, because a
    /// translocated bundle can't see its own original path.
    static let recommendedInstallPath = "/Applications/WhisperPilot.app"

    /// Shell command that clears the quarantine flag and so stops translocation
    /// for good. Offered for copy-to-clipboard rather than run automatically:
    /// this touches a path outside our sandbox and the user should see exactly
    /// what they're running.
    static let remedyCommand = "xattr -dr com.apple.quarantine \(recommendedInstallPath)"

    /// User-facing explanation. Long, because the symptom (re-granting Screen
    /// Recording on every launch) is bizarre enough that a short note would
    /// read as hand-waving.
    static let translocationMessage = """
        ⚠️ macOS is running Whisper Pilot from a temporary randomized location, \
        so it treats the app as brand new every time you open it — that's why \
        Screen Recording and Microphone permissions keep resetting and have to \
        be re-added on each launch.

        This happens when the app is opened straight from the .dmg or the \
        Downloads folder while still flagged as downloaded. To fix it \
        permanently: quit Whisper Pilot, move it to your Applications folder, \
        then run this in Terminal and reopen it:

        \(remedyCommand)
        """
}
