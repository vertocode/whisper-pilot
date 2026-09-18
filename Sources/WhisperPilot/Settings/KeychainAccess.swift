import Foundation

/// Whether Whisper Pilot can use the API keys saved in the macOS Keychain
/// right now, without macOS interrupting the user with a dialog.
enum KeychainAccess: Equatable, Sendable {
    /// No API key is saved, so there is nothing to unlock.
    case noKeysStored
    /// Saved keys were opened and are held in memory for this launch.
    case ready
    /// A key is saved, but the user has not approved this build yet (first
    /// launch, or the app was updated). Approval happens in onboarding.
    case needsUnlock
    /// The user, or macOS, refused access. Only an explicit retry asks again.
    case denied
}
