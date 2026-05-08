import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    private var menuBar: MenuBarController?
    private var overlay: OverlayWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let actions = OverlayActions(
            toggleListening: { [weak self] in
                Task { await self?.coordinator.toggleListening() }
            },
            openSettings: {
                SettingsLauncher.open()
            },
            hideOverlay: { [weak self] in
                self?.overlay?.window?.orderOut(nil)
            }
        )

        let overlay = OverlayWindowController(state: coordinator.overlayState, settings: coordinator.settings, actions: actions)
        self.overlay = overlay
        overlay.showWindow(nil)

        menuBar = MenuBarController(coordinator: coordinator, overlay: overlay)

        Task { await coordinator.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await coordinator.shutdown() }
    }
}
