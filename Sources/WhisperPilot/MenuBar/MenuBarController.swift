import AppKit

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

@MainActor
final class MenuBarController {
    private let coordinator: AppCoordinator
    private let overlay: OverlayWindowController
    private let item: NSStatusItem
    private let menu = NSMenu()

    init(coordinator: AppCoordinator, overlay: OverlayWindowController) {
        self.coordinator = coordinator
        self.overlay = overlay
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
                // Belt-and-braces fallback so the user always sees *something* to click.
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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
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

    @objc private func openSettings() {
        SettingsLauncher.open()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
