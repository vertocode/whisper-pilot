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
            let symbol = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Whisper Pilot")
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Pilot")
            if let symbol {
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
}
