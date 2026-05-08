import SwiftUI

/// The SwiftUI App body is intentionally minimal — it exists only to host the
/// `@NSApplicationDelegateAdaptor` so we can run a real `NSApplicationDelegate`
/// alongside SwiftUI. Every window in this app (overlay, settings) is created and
/// owned by `AppDelegate`, not by a SwiftUI `Scene`. That avoids the silent
/// `showSettingsWindow:` no-op trap that hits accessory / LSUIElement apps on
/// recent macOS SDKs.
@main
struct WhisperPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
