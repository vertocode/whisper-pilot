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
            },
            requestHelpAI: { [weak self] in
                print("[WP] action.requestHelpAI fired")
                self?.coordinator.requestHelpAI()
            },
            goToSessions: { [weak self] in
                print("[WP] action.goToSessions fired")
                Task { [weak self] in
                    await self?.coordinator.stopListening()
                    self?.overlay?.window?.orderOut(nil)
                    self?.showSessionsWindow()
                }
            },
            dismissMessage: { [weak self] id in
                self?.coordinator.overlayState.removeMessage(id: id)
            },
            runSelfTest: { [weak self] in
                Task { await self?.coordinator.runRecognitionSelfTest() }
            },
            runMicTest: { [weak self] in
                Task { await self?.coordinator.runMicTest() }
            },
            runAudioTest: { [weak self] in
                Task { await self?.coordinator.runSystemAudioTest() }
            },
            toggleMicMute: { [weak self] in
                self?.coordinator.overlayState.isMicrophoneMuted.toggle()
            },
            toggleSystemAudioMute: { [weak self] in
                self?.coordinator.overlayState.isSystemAudioMuted.toggle()
            },
            exportTranscript: { [weak self] in
                self?.exportCurrentTranscript()
            }
        )

        let overlay = OverlayWindowController(state: coordinator.overlayState, settings: coordinator.settings, actions: actions)
        self.overlay = overlay
        // Don't show overlay until a session is picked.

        let vm = SessionsViewModel()
        vm.onStartNew = { [weak self] meta in self?.openSession(meta, resumed: false) }
        vm.onResume = { [weak self] meta in self?.openSession(meta, resumed: true) }
        sessionsViewModel = vm

        let sessions = SessionsWindowController(viewModel: vm, globalContext: coordinator.globalContext)
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

    /// Read-only export: copies the active session's `transcript.md` to a user-chosen
    /// path via the standard macOS save panel. The original on-disk transcript stays
    /// untouched. No-op if no session is active (the overlay shouldn't be visible in that
    /// case anyway, so this is purely defensive).
    private func exportCurrentTranscript() {
        guard let session = coordinator.currentSession else {
            wpWarn("Export transcript: no active session — nothing to export")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        let sanitizedName = session.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(sanitizedName).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let markdown = await SessionStore.shared.loadTranscriptMarkdown(session.id)
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    wpInfo("Exported transcript (\(markdown.count) bytes) to \(url.path)")
                } catch {
                    wpError("Export transcript failed: \(error.localizedDescription)")
                }
            }
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
