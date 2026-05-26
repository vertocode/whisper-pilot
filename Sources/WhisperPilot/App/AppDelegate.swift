import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    private var menuBar: MenuBarController?
    private var overlay: OverlayWindowController?
    private var sessionsWindow: SessionsWindowController?
    private var sessionsViewModel: SessionsViewModel?
    private var settingsWindow: NSWindow?
    /// Global shortcut for "toggle overlay visibility". Held here so it lives as
    /// long as the app does; reassigned whenever the user picks a different
    /// combo in Settings.
    private var toggleOverlayHotKey: GlobalHotKey?
    private var settingsCancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Start the crash logger BEFORE anything else so the earliest possible
        // wpInfo / wpError lines + any startup crash land on disk. The
        // unclean-shutdown check immediately below uses its sentinel.
        CrashLogger.shared.start()
        if CrashLogger.shared.wasLastRunUnclean() {
            wpWarn("Previous Whisper Pilot session did not shut down cleanly — see runtime.log for the last activity before it died. Log: \(CrashLogger.shared.logFilePath)")
            if let tail = CrashLogger.shared.logTail(bytes: 4_000), !tail.isEmpty {
                // Trim to the last few lines so the UI alert badge isn't overwhelmed
                // — the full log is still on disk for deeper inspection.
                let lastLines = tail.split(separator: "\n").suffix(20).joined(separator: "\n")
                wpWarn("Tail of previous runtime.log:\n\(lastLines)")
            }
        }
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
            },
            runChatAction: { [weak self] action in
                self?.handleChatAction(action)
            }
        )

        let overlay = OverlayWindowController(state: coordinator.overlayState, settings: coordinator.settings, actions: actions)
        self.overlay = overlay
        // Don't show overlay until a session is picked.

        // Register the user-configurable global shortcut for show/hide. Re-bind
        // whenever the setting changes so the user gets immediate feedback when
        // they record a new combo.
        registerToggleOverlayHotKey(coordinator.settings.toggleOverlayShortcut)
        coordinator.settings.$toggleOverlayShortcut
            .dropFirst()
            .sink { [weak self] new in self?.registerToggleOverlayHotKey(new) }
            .store(in: &settingsCancellables)

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

    /// Resolve an inline-button action posted from a system note. Today there's
    /// only one such action — flipping the Force-SCK setting and bouncing the
    /// listening pipeline so the change takes effect immediately — but new
    /// cases get added here as future watchdog messages grow buttons.
    func handleChatAction(_ action: ChatMessageAction) {
        switch action {
        case .enableForceSCKAndRestart:
            coordinator.settings.forceScreenCaptureKitForSystemAudio = true
            // The capture-path decision is made inside `startListening`, so a
            // running session needs a stop+start to pick up the new setting.
            // If nothing is running, just save the setting and let the user
            // click ▶ themselves — bouncing nothing would surface a confusing
            // "Starting…" state.
            Task { [coordinator] in
                if await coordinator.isRunning {
                    await coordinator.stopListening()
                    await coordinator.startListening()
                }
                await MainActor.run {
                    coordinator.overlayState.appendSystemNote(
                        "ℹ️ ScreenCaptureKit enabled for system audio. macOS will ask for Screen Recording permission on the next Play if it hasn't already.",
                        category: .transcript
                    )
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await coordinator.shutdown() }
        // Mark a clean shutdown so the next launch doesn't false-alarm
        // "previous run ended unexpectedly". Runs after the coordinator's
        // own shutdown is queued — the sentinel removal is what differentiates
        // a clean exit from a kernel-killed one.
        CrashLogger.shared.markCleanShutdown()
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

    /// Drops any existing global hotkey and installs a new one for the given
    /// binding. Called once at launch and again every time the user records a
    /// different combo in Settings. If registration fails (e.g. another app has
    /// claimed the same combo), the previous hotkey is gone and `toggleOverlayHotKey`
    /// ends up nil — the user-visible symptom is that the new combo just doesn't
    /// fire, which is the correct behavior in a name-collision.
    private func registerToggleOverlayHotKey(_ binding: ShortcutBinding) {
        toggleOverlayHotKey = nil
        toggleOverlayHotKey = GlobalHotKey(
            keyCode: binding.keyCode,
            nsModifiers: binding.modifiers
        ) { [weak self] in
            self?.overlay?.toggleVisibility()
        }
        if toggleOverlayHotKey != nil {
            wpInfo("AppDelegate: registered toggle-overlay hotkey \(binding.displayLabel)")
        }
    }
}
