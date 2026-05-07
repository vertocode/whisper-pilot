import SwiftUI

@main
struct WhisperPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(store: delegate.coordinator.settings)
        }
    }
}
