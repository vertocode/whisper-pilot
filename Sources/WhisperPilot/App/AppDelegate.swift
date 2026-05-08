import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    private var menuBar: MenuBarController?
    private var overlay: OverlayWindowController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let actions = OverlayActions(
            toggleListening: { [weak self] in
                Task { await self?.coordinator.toggleListening() }
            },
            openSettings: { [weak self] in
                self?.showSettings()
            },
            hideOverlay: { [weak self] in
                self?.overlay?.window?.orderOut(nil)
            }
        )

        let overlay = OverlayWindowController(state: coordinator.overlayState, settings: coordinator.settings, actions: actions)
        self.overlay = overlay
        overlay.showWindow(nil)

        menuBar = MenuBarController(
            coordinator: coordinator,
            overlay: overlay,
            openSettings: { [weak self] in self?.showSettings() }
        )

        Task { await coordinator.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await coordinator.shutdown() }
    }

    /// Owns the Settings window directly. We don't rely on SwiftUI's `Settings { }` scene
    /// because the magic `showSettingsWindow:` action selector is silently a no-op for
    /// accessory / LSUIElement apps on recent macOS SDKs — clicks on the gear icon would
    /// do nothing and leave no error in the console.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Whisper Pilot Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(store: coordinator.settings))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
