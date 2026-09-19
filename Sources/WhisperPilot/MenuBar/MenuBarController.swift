import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let overlay: OverlayWindowController
    private let openSettings: () -> Void
    private let openSessions: () -> Void
    private let openSetup: () -> Void
    /// True while a permission the app needs is missing. The listening and
    /// session entries can't work then, so the menu offers "Finish setup" instead.
    private let needsSetup: () -> Bool
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var listeningActive = false
    private var observers: Set<AnyCancellable> = []

    init(
        coordinator: AppCoordinator,
        overlay: OverlayWindowController,
        openSettings: @escaping () -> Void,
        openSessions: @escaping () -> Void,
        openSetup: @escaping () -> Void,
        needsSetup: @escaping () -> Bool
    ) {
        self.coordinator = coordinator
        self.overlay = overlay
        self.openSettings = openSettings
        self.openSessions = openSessions
        self.openSetup = openSetup
        self.needsSetup = needsSetup
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
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

        menu.delegate = self
        item.menu = menu
        rebuildMenu()

        // Rebuild when a permission or the Keychain state changes, so the menu
        // never offers something that can't work yet (or hides what now can).
        coordinator.permissions.$snapshot
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuildMenu() } }
            .store(in: &observers)
        coordinator.settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuildMenu() } }
            .store(in: &observers)

        let stream = coordinator.overlayState.statusStream
        Task { [weak self] in
            for await status in stream {
                self?.listeningActive = status.isActive
                self?.updateToggleTitle(running: status.isActive)
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for entry in MenuLayout.entries(needsSetup: needsSetup(), listeningActive: listeningActive) {
            switch entry {
            case .finishSetup:
                addItem("Finish setup…", #selector(openSetupAction))
            case .toggleListening(let running):
                let toggle = addItem(running ? "Stop listening" : "Start listening", #selector(toggleListening), key: "l")
                toggle.tag = 1
            case .showOverlay:
                addItem("Show overlay", #selector(showOverlay), key: "o")
            case .sessions:
                addItem("Sessions…", #selector(openSessionsAction), key: "s")
            case .settings:
                addItem("Settings…", #selector(openSettingsAction), key: ",")
            case .separator:
                menu.addItem(.separator())
            case .about:
                addItem("About Whisper Pilot", #selector(showAbout))
            case .quit:
                addItem("Quit Whisper Pilot", #selector(quit), key: "q")
            }
        }
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    private func updateToggleTitle(running: Bool) {
        if let toggle = menu.item(withTag: 1) {
            toggle.title = running ? "Stop listening" : "Start listening"
        }
    }

    /// The user may have changed a permission in System Settings while the app
    /// was in the background, so check again each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        Task { await coordinator.permissions.refresh() }
    }

    @objc private func openSetupAction() {
        openSetup()
    }

    @objc private func toggleListening() {
        // Starting with no session selected would transcribe into RAM only —
        // the persistence layer drops every line without a session id, so a
        // whole meeting could silently vanish. Route to the Sessions window
        // so the user picks (or creates) a session first.
        if !coordinator.isRunning, coordinator.currentSession == nil {
            openSessions()
            return
        }
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
