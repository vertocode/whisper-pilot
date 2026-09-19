import Foundation

/// The four Keychain operations `SettingsStore` needs. The app uses the real
/// Keychain; tests use an in-memory fake, so no test can raise a macOS dialog.
protocol SecretStore: Sendable {
    /// Identity of the running build; see `KeychainHelper.buildIdentity`.
    var buildIdentity: String { get }
    /// Whether an item exists, without reading its secret.
    func exists(_ key: String) -> Bool
    /// Reads the secret. This is the call that can show the macOS dialog.
    func read(_ key: String) -> KeychainHelper.ReadResult
    /// Stores the value, or deletes it when nil or empty.
    func set(_ value: String?, forKey key: String) -> OSStatus
}

struct SystemSecretStore: SecretStore {
    var buildIdentity: String { KeychainHelper.buildIdentity }
    func exists(_ key: String) -> Bool { KeychainHelper.exists(key) }
    func read(_ key: String) -> KeychainHelper.ReadResult { KeychainHelper.read(key) }
    func set(_ value: String?, forKey key: String) -> OSStatus { KeychainHelper.set(value, forKey: key) }
}
