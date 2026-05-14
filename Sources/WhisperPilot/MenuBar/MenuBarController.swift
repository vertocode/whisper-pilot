import AppKit

@MainActor
final class MenuBarController {
    private let coordinator: AppCoordinator
    private let overlay: OverlayWindowController
    private let openSettings: () -> Void
    private let openSessions: () -> Void
    private let item: NSStatusItem
    private let menu = NSMenu()

    init(
        coordinator: AppCoordinator,
        overlay: OverlayWindowController,
        openSettings: @escaping () -> Void,
        openSessions: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.overlay = overlay
        self.openSettings = openSettings
        self.openSessions = openSessions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configure()
    }

    private func configure() {
        if let button = item.button {
            // Brand logo first, with the same two-step fallback chain `BrandLogo`
            // uses (asset catalog → raw PNG → SF Symbol → text). Keeps the menu
            // bar icon visually consistent with the Sessions header and the
            // Settings header, regardless of how the app was built.
            if let logo = BrandLogo.loadBrandLogo() {
                logo.size = NSSize(width: 18, height: 18)
                button.image = logo
                button.imagePosition = .imageOnly
            } else if let symbol = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Whisper Pilot")
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Pilot") {
                button.image = symbol
                button.imagePosition = .imageOnly
            } else {
                button.title = "WP"
            }
            button.toolTip = "Whisper Pilot"
        }

        let toggle = NSMenuItem(title: "Start listening", action: #selector(toggleListening), keyEquivalent: "l")
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)

        let showOverlay = NSMenuItem(title: "Show overlay", action: #selector(showOverlay), keyEquivalent: "o")
        showOverlay.target = self
        menu.addItem(showOverlay)

        menu.addItem(.separator())

        let sessions = NSMenuItem(title: "Sessions…", action: #selector(openSessionsAction), keyEquivalent: "s")
        sessions.target = self
        menu.addItem(sessions)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Whisper Pilot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Whisper Pilot", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu

        let stream = coordinator.overlayState.statusStream
        Task { [weak self] in
            for await status in stream {
                self?.updateToggleTitle(running: status.isActive)
            }
        }
    }

    private func updateToggleTitle(running: Bool) {
        if let toggle = menu.item(withTag: 1) {
            toggle.title = running ? "Stop listening" : "Start listening"
        }
    }

    @objc private func toggleListening() {
        Task { await coordinator.toggleListening() }
    }

    @objc private func showOverlay() {
        overlay.showWindow(nil)
        overlay.window?.orderFrontRegardless()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func openSessionsAction() {
        openSessions()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Shows the macOS-standard About panel — picks up the app icon from the asset
    /// catalog automatically, and the version comes from the Info.plist. We pass
    /// `credits` so the panel mentions the license and the project URL without us
    /// having to build a custom About window.
    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let creditsText = NSMutableAttributedString(string: """
            Ambient, local-first AI co-pilot for live conversations.

            Open source under the MIT license.
            github.com/vertocode/whisper-pilot
            """)
        // Make the URL clickable in the credits area.
        if let range = creditsText.string.range(of: "github.com/vertocode/whisper-pilot") {
            let nsRange = NSRange(range, in: creditsText.string)
            creditsText.addAttribute(.link, value: "https://github.com/vertocode/whisper-pilot", range: nsRange)
        }
        creditsText.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            range: NSRange(location: 0, length: creditsText.length)
        )

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "Whisper Pilot",
            NSApplication.AboutPanelOptionKey.applicationVersion: version,
            NSApplication.AboutPanelOptionKey.credits: creditsText,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Whisper Pilot contributors"
        ])
    }
}
