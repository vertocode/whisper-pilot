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
    var openScreenRecordingPrivacy: () -> Void
    var toggleAIPaused: () -> Void
    /// (text, withScreenshot) — when `withScreenshot` is true, the coordinator captures
    /// the current display and ships it as multimodal input.
    var sendUserPrompt: (String, Bool) -> Void
    /// Stops listening, hides the overlay, brings the Sessions window back to front so
    /// the user can pick a different session or start a new one.
    var goToSessions: () -> Void
    /// Dismiss a chat message by id (used by the close button on system notes).
    var dismissMessage: (UUID) -> Void
    /// Run the recognition self-test (synthesizes speech → feeds to recognizer → reports).
    var runSelfTest: () -> Void
    /// Mic Test: spins up an AVAudioEngine, taps mic, reports RMS over 3 seconds.
    var runMicTest: () -> Void
    /// System Audio Test: Process Tap captures system audio, reports RMS over 3 seconds.
    var runAudioTest: () -> Void
    /// Toggle the microphone mute state.
    var toggleMicMute: () -> Void
    /// Toggle the system audio mute state.
    var toggleSystemAudioMute: () -> Void
}

/// Translucent floating window. We use a real `NSWindow` (not `NSPanel`) so window managers
/// like BetterSnapTool, Rectangle, and macOS's own snap-to-edge can manage and resize it.
/// The chrome is hidden (transparent title bar, all traffic lights hidden) so it still looks
/// like a borderless overlay, but the OS treats it as a first-class window.
@MainActor
final class OverlayWindowController: NSWindowController {
    private let state: OverlayState
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(state: OverlayState, settings: SettingsStore, actions: OverlayActions) {
        self.state = state
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Pilot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 320, height: 220)

        let host = NSHostingView(rootView: OverlayView(state: state, actions: actions))
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host

        super.init(window: window)

        positionInTopRight(window)
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

    private func positionInTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        window.setFrameOrigin(origin)
    }

    private func applyAlwaysOnTop(_ on: Bool) {
        // We use `.floating` (3) rather than `.statusBar` (25) so the Settings window at
        // `.popUpMenu` still wins z-order, AND so window managers like BetterSnapTool can
        // still manipulate the window (they often refuse to touch windows above .modalPanel).
        window?.level = on ? .floating : .normal
    }

    private func applyClickThrough(_ on: Bool) {
        window?.ignoresMouseEvents = on
    }
}
