import AppKit
import Combine
import SwiftUI

/// Closures the overlay invokes on the coordinator. Passed in at construction time so the
/// SwiftUI overlay never directly imports the coordinator.
@MainActor
struct OverlayActions {
    var toggleListening: () -> Void
    var openSettings: () -> Void
    var hideOverlay: () -> Void
}

/// Translucent floating panel. Borderless so we don't have traffic lights or an empty
/// title-bar strip; the SwiftUI content provides its own controls and is draggable via
/// the window background.
@MainActor
final class OverlayWindowController: NSWindowController {
    private let state: OverlayState
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(state: OverlayState, settings: SettingsStore, actions: OverlayActions) {
        self.state = state
        self.settings = settings

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .vibrantDark)

        let host = NSHostingView(rootView: OverlayView(state: state, actions: actions))
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

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

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
