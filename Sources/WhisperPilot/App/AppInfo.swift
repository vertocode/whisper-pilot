import Foundation

/// Static accessors for the app's bundle metadata. Kept in one place so the
/// "Whisper Pilot v0.1.0" label rendered by the Settings header, Sessions
/// header, and About panel all read from the same source — the canonical
/// `CFBundleShortVersionString` in Info.plist.
enum AppInfo {
    /// Marketing version string ("0.1.0"). Falls back to "?" only if the
    /// Info.plist is missing the key, which would itself be a build error.
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }()

    /// "Whisper Pilot v0.1.0" — the formatted brand label used by SwiftUI
    /// headers. Centralized so renaming or reformatting only happens once.
    static let brandLabel: String = "Whisper Pilot v\(version)"
}
