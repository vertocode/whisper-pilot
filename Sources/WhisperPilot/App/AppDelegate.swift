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
    private var onboardingWindow: OnboardingWindowController?
    /// Global shortcut for "toggle overlay visibility". Held here so it lives as
    /// long as the app does; reassigned whenever the user picks a different
    /// combo in Settings.
    private var toggleOverlayHotKey: GlobalHotKey?
    /// Global shortcut for "answer what's on screen" (⌘⇧A by default). Same
    /// lifetime story as `toggleOverlayHotKey` — held for the app's lifetime,
    /// re-bound when the user picks a new combo.
    private var answerScreenHotKey: GlobalHotKey?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var terminationReplySent = false

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
            openSetup: { [weak self] in
                print("[WP] action.openSetup fired")
                self?.showOnboarding(start: .permissions)
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
            requestSummary: { [weak self] in
                print("[WP] action.requestSummary fired")
                self?.coordinator.requestSummary()
            },
            requestActionItems: { [weak self] in
                print("[WP] action.requestActionItems fired")
                self?.coordinator.requestActionItems()
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
            },
            selectModel: { [weak self] modelID in
                self?.coordinator.selectModel(modelID)
            },
            setLayoutMode: { [weak self] mode in
                print("[WP] action.setLayoutMode fired (\(mode.rawValue))")
                self?.coordinator.settings.applyOverlayLayoutMode(mode)
            },
            adoptTranslationSession: { [weak self] session in
                self?.coordinator.adoptTranslationSession(session)
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

        registerAnswerScreenHotKey(coordinator.settings.answerScreenShortcut)
        coordinator.settings.$answerScreenShortcut
            .dropFirst()
            .sink { [weak self] new in self?.registerAnswerScreenHotKey(new) }
            .store(in: &settingsCancellables)

        let vm = SessionsViewModel()
        vm.onStartNew = { [weak self] meta in self?.openSession(meta, resumed: false) }
        vm.onResume = { [weak self] meta in self?.openSession(meta, resumed: true) }
        vm.onOpenSettings = { [weak self] in self?.showSettings() }
        sessionsViewModel = vm

        let sessions = SessionsWindowController(viewModel: vm, globalContext: coordinator.globalContext)
        sessionsWindow = sessions

        menuBar = MenuBarController(
            coordinator: coordinator,
            overlay: overlay,
            openSettings: { [weak self] in self?.showSettings() },
            openSessions: { [weak self] in self?.showSessionsWindow() },
            openSetup: { [weak self] in self?.showOnboarding(start: .permissions) },
            needsSetup: { [weak self] in !(self?.missingSetupItems().isEmpty ?? true) }
        )

        coordinator.requestSetup = { [weak self] in
            self?.showOnboarding(start: .permissions)
        }

        Task {
            await coordinator.bootstrap()
            showInitialWindow()
        }
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
                if coordinator.isRunning {
                    await coordinator.restartListening()
                }
                coordinator.overlayState.appendSystemNote(
                    "ℹ️ ScreenCaptureKit enabled for system audio. macOS will ask for Screen Recording permission on the next Play if it hasn't already.",
                    category: .transcript
                )
            }
        case .copyQuarantineFixCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(InstallDiagnostics.remedyCommand, forType: .string)
            coordinator.overlayState.appendSystemNote(
                "📋 Copied. Quit Whisper Pilot, make sure it's in your Applications folder, paste the command into Terminal, then reopen the app.",
                category: .general
            )
        case .shedMicrophoneForSession:
            // Session-scoped: mute the mic channel so the recognizer stops being
            // fed. No setting is persisted — the user can re-enable via the mic
            // toggle, and the next session starts unmuted.
            coordinator.shedMicrophoneForSession()
        }
    }

    /// Delay termination until the coordinator has actually flushed its pending
    /// transcript lines / context saves. A fire-and-forget Task from
    /// `applicationWillTerminate` loses the race against process exit, silently
    /// dropping the last utterance and the most recent context edits. The
    /// timeout guards against a hung shutdown keeping the app alive forever.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor [coordinator] in
            await coordinator.shutdown()
            guard !terminationReplySent else { return }
            terminationReplySent = true
            CrashLogger.shared.markCleanShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !terminationReplySent else { return }
            terminationReplySent = true
            wpWarn("Shutdown timed out after 5 seconds; terminating without a clean-shutdown marker")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
            window.contentView = NSHostingView(rootView: SettingsView(
                store: coordinator.settings,
                // Lets the Translation tab's enable toggle take effect on a
                // session that's already listening, instead of waiting for the
                // next ▶.
                onTranslationConfigurationChanged: { [weak coordinator] in
                    coordinator?.translationSettingsChanged()
                },
                onOpenSetup: { [weak self] in
                    self?.showOnboarding(start: .permissions)
                }
            ))
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

    private func showInitialWindow() {
        let settings = coordinator.settings
        let missing = missingSetupItems()
        let hasAIKey = !settings.availableVendors.isEmpty
        let shouldShowOnboarding = OnboardingEligibility.shouldPresent(
            completedVersion: settings.onboardingCompletedVersion,
            currentVersion: SettingsStore.currentOnboardingVersion,
            deferredForThisBuild: settings.isSetupDeferredForThisBuild,
            missing: missing,
            hasAIKey: hasAIKey
        )

        if shouldShowOnboarding {
            showOnboarding(start: OnboardingEligibility.startPoint(
                completedVersion: settings.onboardingCompletedVersion,
                missing: missing,
                permissions: coordinator.permissions.snapshot
            ))
        } else {
            if missing.isEmpty, hasAIKey, settings.onboardingCompletedVersion < SettingsStore.currentOnboardingVersion {
                settings.completeOnboarding()
            }
            showSessionsWindow()
        }
    }

    private func missingSetupItems() -> [SetupItem] {
        let settings = coordinator.settings
        return OnboardingEligibility.missing(
            captureMicrophone: settings.captureMicrophone,
            requiresScreenRecording: settings.forceScreenCaptureKitForSystemAudio || !PermissionsManager.processTapSupported,
            processTapSupported: PermissionsManager.processTapSupported,
            permissions: coordinator.permissions.snapshot,
            keychain: settings.keychainAccess
        )
    }

    /// Opens (or brings forward) the one place where every permission is
    /// requested. Also reachable from Settings and from overlay banners.
    func showOnboarding(start: OnboardingStart) {
        if let existing = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = OnboardingWindowController(
            rootView: OnboardingView(
                permissions: coordinator.permissions,
                settings: coordinator.settings,
                start: start,
                bringToFront: { [weak self] in
                    // macOS hands focus back to the previous app a moment after
                    // its dialog closes, so ask again shortly after as well.
                    for delay in [0.0, 0.3, 1.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let window = self?.onboardingWindow?.window else { return }
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                },
                onFinish: { [weak self] in
                    self?.finishOnboarding()
                }
            )
        )
        // The close button counts as "later": remember it for this build so the
        // window doesn't come straight back, and never leave the app with no window.
        controller.onClose = { [weak self] in
            guard let self else { return }
            let settings = self.coordinator.settings
            if !self.missingSetupItems().isEmpty || settings.onboardingCompletedVersion < SettingsStore.currentOnboardingVersion {
                settings.deferSetupForThisBuild()
            }
            self.onboardingWindow = nil
            self.showSessionsUnlessSessionIsOpen()
        }
        onboardingWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Onboarding can be reopened mid-session from an overlay banner; the
    /// Sessions window should not pop over the session the user is in.
    private func showSessionsUnlessSessionIsOpen() {
        guard overlay?.window?.isVisible != true else { return }
        showSessionsWindow()
    }

    private func finishOnboarding() {
        coordinator.settings.completeOnboarding()
        onboardingWindow?.onClose = nil
        onboardingWindow?.close()
        onboardingWindow = nil
        showSessionsUnlessSessionIsOpen()
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

    /// Drops any existing "answer screen" hotkey and installs a new one. On fire,
    /// it brings the overlay forward (so the answer is visible even if the overlay
    /// was hidden or the user is in another app) and asks the coordinator to
    /// capture the screen and answer whatever question is on it. Same
    /// collision-handling semantics as `registerToggleOverlayHotKey`.
    private func registerAnswerScreenHotKey(_ binding: ShortcutBinding) {
        answerScreenHotKey = nil
        answerScreenHotKey = GlobalHotKey(
            keyCode: binding.keyCode,
            nsModifiers: binding.modifiers
        ) { [weak self] in
            guard let self else { return }
            print("[WP] answer-screen hotkey fired")
            // Surface the overlay so the streamed answer is visible. Don't steal
            // focus from the app the user is reading (no NSApp.activate) — the
            // overlay floats above without taking key window.
            self.overlay?.showWindow(nil)
            self.overlay?.window?.orderFrontRegardless()
            self.coordinator.answerScreen()
        }
        if answerScreenHotKey != nil {
            wpInfo("AppDelegate: registered answer-screen hotkey \(binding.displayLabel)")
        }
    }
}
