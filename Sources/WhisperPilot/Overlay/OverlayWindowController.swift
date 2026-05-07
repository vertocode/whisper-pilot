import AppKit
import Combine
import SwiftUI

/// Translucent floating panel. We use `NSPanel` with `.nonactivatingPanel` so showing the overlay
/// doesn't pull focus from the meeting window.
@MainActor
final class OverlayWindowController: NSWindowController {
    private let state: OverlayState
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(state: OverlayState, settings: SettingsStore) {
        self.state = state
        self.settings = settings

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Whisper Pilot"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let host = NSHostingView(rootView: OverlayView(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        super.init(window: panel)

        positionInTopRight(panel)
        applyAlwaysOnTop(settings.alwaysOnTop)
        applyClickThrough(settings.clickThrough)

        settings.$alwaysOnTop
            .sink { [weak self] in self?.applyAlwaysOnTop($0) }
            .store(in: &cancellables)

        settings.$clickThrough
            .sink { [weak self] in self?.applyClickThrough($0) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func positionInTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }

    private func applyAlwaysOnTop(_ on: Bool) {
        window?.level = on ? .statusBar : .floating
    }

    private func applyClickThrough(_ on: Bool) {
        window?.ignoresMouseEvents = on
    }
}
