import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    private var menuBar: MenuBarController?
    private var overlay: OverlayWindowController?
    private var sessionsWindow: SessionsWindowController?
    private var sessionsViewModel: SessionsViewModel?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        print("[WP] applicationDidFinishLaunching")

        let actions = OverlayActions(
            toggleListening: { [weak self] in
                print("[WP] action.toggleListening fired")
                Task { await self?.coordinator.toggleListening() }
            },
            openSettings: { [weak self] in
                print("[WP] action.openSettings fired")
                self?.showSettings()
            },
            hideOverlay: { [weak self] in
                print("[WP] action.hideOverlay fired")
                self?.overlay?.window?.orderOut(nil)
            },
            openScreenRecordingPrivacy: { [weak self] in
                print("[WP] action.openScreenRecordingPrivacy fired")
                self?.coordinator.permissions.openScreenRecordingSettings()
            },
            toggleAIPaused: { [weak self] in
                print("[WP] action.toggleAIPaused fired")
                self?.coordinator.toggleAIPaused()
            },
            sendUserPrompt: { [weak self] text, withScreenshot in
                print("[WP] action.sendUserPrompt fired (\(text.count) chars, screenshot=\(withScreenshot))")
                self?.coordinator.sendUserPrompt(text, withScreenshot: withScreenshot)
            }
        )

        let overlay = OverlayWindowController(state: coordinator.overlayState, settings: coordinator.settings, actions: actions)
        self.overlay = overlay
        // Don't show overlay until a session is picked.

        let vm = SessionsViewModel()
        vm.onStartNew = { [weak self] meta in self?.openSession(meta, resumed: false) }
        vm.onResume = { [weak self] meta in self?.openSession(meta, resumed: true) }
        sessionsViewModel = vm

        let sessions = SessionsWindowController(viewModel: vm)
        sessionsWindow = sessions
        sessions.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessions.window?.makeKeyAndOrderFront(nil)

        menuBar = MenuBarController(
            coordinator: coordinator,
            overlay: overlay,
            openSettings: { [weak self] in self?.showSettings() },
            openSessions: { [weak self] in self?.showSessionsWindow() }
        )

        Task { await coordinator.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await coordinator.shutdown() }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Whisper Pilot Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.level = .popUpMenu
            window.contentView = NSHostingView(rootView: SettingsView(store: coordinator.settings))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func showSessionsWindow() {
        Task {
            await sessionsViewModel?.refresh()
            sessionsWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            sessionsWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func openSession(_ meta: SessionMeta, resumed: Bool) {
        Task {
            // If a different session is already running, stop it first so we don't mix audio.
            if coordinator.isRunning, coordinator.currentSession?.id != meta.id {
                await coordinator.stopListening()
            }
            await coordinator.useSession(meta, resumed: resumed)
            sessionsWindow?.window?.orderOut(nil)
            overlay?.showWindow(nil)
            overlay?.window?.orderFrontRegardless()
        }
    }
}
