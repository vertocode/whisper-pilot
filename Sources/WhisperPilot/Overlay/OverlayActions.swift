import AppKit
import Foundation

/// Closures the overlay invokes on the coordinator. Passed in at construction time so the
/// SwiftUI overlay never directly imports the coordinator.
@MainActor
struct OverlayActions {
    var toggleListening: () -> Void
    var openSettings: () -> Void
    var hideOverlay: () -> Void
}

/// Convenience for opening the SwiftUI `Settings` scene from anywhere on the main actor.
@MainActor
enum SettingsLauncher {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
