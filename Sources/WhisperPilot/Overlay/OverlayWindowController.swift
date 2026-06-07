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
    /// "Help AI" button: ask the AI to find any unanswered question in the recent
    /// transcript and answer it. No user text needed.
    var requestHelpAI: () -> Void
    /// "Summary" button: AI produces a recap of the meeting from the full
    /// transcript + AI chat. Available at any point during the session.
    var requestSummary: () -> Void
    /// "Action items" button: AI pulls explicit commitments / TODOs from the
    /// transcript + AI chat, or reports that no action items are pending.
    var requestActionItems: () -> Void
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
    /// Save the current session's transcript markdown to a user-chosen location.
    var exportTranscript: () -> Void
    /// Run an inline button action embedded in a system note (e.g., the
    /// no-transcripts watchdog's "Enable Force ScreenCaptureKit and retry"
    /// button). The handler is responsible for both the side effect and any
    /// UI confirmation message.
    var runChatAction: (ChatMessageAction) -> Void
    /// User picked a new model in the overlay's in-session model selector.
    /// Coordinator updates `settings.activeModel` (triggering the provider
    /// rebuild via `refreshDerivedState`) and persists the choice onto the
    /// active session so resuming later restores it.
    var selectModel: (String) -> Void
    /// User picked a layout mode from the overlay's in-session menu. Applies the
    /// preset (size/position/appearance) immediately via the settings store.
    var setLayoutMode: (OverlayLayoutMode) -> Void
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
    /// Set while we programmatically resize/move the window so the manual
    /// resize/move observers don't misread our own `setFrame` as a user drag and
    /// flip the layout mode to `.custom`.
    private var isApplyingLayout = false

    init(state: OverlayState, settings: SettingsStore, actions: OverlayActions) {
        self.state = state
        self.settings = settings

        let defaultSize = Self.defaultContentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
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
        // Matches the SwiftUI root's `.frame(minWidth: 340, minHeight: 150)` in
        // OverlayView. Kept low so the short modes (Interview) can actually be
        // short — just header + a line or two of AI answer + composer — instead of
        // being floored at a half-screen height.
        window.minSize = NSSize(width: 340, height: 150)

        let host = NSHostingView(rootView: OverlayView(state: state, settings: settings, actions: actions))
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host

        super.init(window: window)

        positionInTopRight(window)
        // Persist user-driven resize and reposition across launches. First launch (no
        // saved frame) uses the screen-relative default size + top-right placement we
        // just configured; subsequent launches restore whatever the user last left it
        // at. Must be called *after* the default frame is set so the autosave snapshot
        // for first-run users captures the new default, not the prior init value.
        window.setFrameAutosaveName("WhisperPilotOverlay")
        applyAlwaysOnTop(settings.alwaysOnTop)
        applyClickThrough(settings.clickThrough)
        applyHideFromScreenSharing(settings.hideFromScreenSharing)

        // A non-custom layout mode owns the window frame: re-apply it on launch so
        // the user lands in their chosen preset every time. In `.custom` mode we
        // leave the autosaved (user-dragged) frame untouched.
        if settings.overlayLayoutMode != .custom {
            applyLayout()
        }

        settings.$alwaysOnTop
            .sink { [weak self] in self?.applyAlwaysOnTop($0) }
            .store(in: &cancellables)

        settings.$clickThrough
            .sink { [weak self] in self?.applyClickThrough($0) }
            .store(in: &cancellables)

        settings.$hideFromScreenSharing
            .sink { [weak self] in self?.applyHideFromScreenSharing($0) }
            .store(in: &cancellables)

        // Size/position settings apply live. Each publisher is `dropFirst`-ed
        // individually so none of the three initial `@Published` emissions fires
        // `applyLayout` on launch — that's handled above for preset modes only, so
        // a custom user's autosaved frame survives. Only genuine changes propagate.
        Publishers.Merge3(
            settings.$overlayWidthFraction.dropFirst().map { _ in () },
            settings.$overlayHeightFraction.dropFirst().map { _ in () },
            settings.$overlayPosition.dropFirst().map { _ in () }
        )
        .sink { [weak self] in self?.applyLayout() }
        .store(in: &cancellables)

        // A user-driven resize or move means "I want it like this" — flip the mode
        // to `.custom` so the window's frame autosave (not a preset) governs from
        // here on. `didEndLiveResize` never fires for our programmatic `setFrame`;
        // the move observer is guarded by `isApplyingLayout` for the same reason.
        if let window = self.window {
            NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification, object: window)
                .sink { [weak self] _ in self?.markLayoutCustomized() }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window)
                .sink { [weak self] _ in
                    guard let self, !self.isApplyingLayout else { return }
                    self.markLayoutCustomized()
                }
                .store(in: &cancellables)
        }
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

    /// Sizes and positions the window from the current layout settings: width/height
    /// as fractions of the active screen's visible area, anchored to the configured
    /// corner/edge. Clamped to the window's `minSize` so a tiny preset can't make the
    /// content un-usable. Guarded by `isApplyingLayout` so our own `setFrame` isn't
    /// mistaken for a user drag.
    func applyLayout() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let rawWidth = visible.width * CGFloat(settings.overlayWidthFraction)
        let rawHeight = visible.height * CGFloat(settings.overlayHeightFraction)
        let size = NSSize(
            width: min(visible.width, max(window.minSize.width, rawWidth)),
            height: min(visible.height, max(window.minSize.height, rawHeight))
        )
        let origin = settings.overlayPosition.origin(in: visible, size: size, inset: 16)
        isApplyingLayout = true
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        // Clear the guard on the next runloop tick rather than inline: AppKit may
        // post `didMove`/`didResize` for our own `setFrame` slightly after the call
        // returns, and clearing too early would let those be misread as a user drag
        // and flip the mode to Custom.
        DispatchQueue.main.async { [weak self] in self?.isApplyingLayout = false }
    }

    /// Records that the user took manual control of the window's size/position by
    /// dragging it. Flips the layout mode to `.custom` so a preset doesn't snap the
    /// window back on the next change or launch.
    private func markLayoutCustomized() {
        guard settings.overlayLayoutMode != .custom else { return }
        wpInfo("Overlay: manual resize/move — switching layout mode to Custom")
        settings.overlayLayoutMode = .custom
    }

    /// Default content size: half the screen's visible width and height (one quarter
    /// of the visible area), clamped to a sensible window — small enough to leave
    /// room around the window on laptop screens, big enough to actually show both
    /// the AI chat and live transcript without immediately needing a resize.
    private static func defaultContentSize() -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = max(480, min(1200, visible.width / 2))
        let height = max(360, min(900, visible.height / 2))
        return NSSize(width: width, height: height)
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

    /// `.none` excludes the window from every screen-capture API on macOS
    /// (WebRTC `getDisplayMedia`, ScreenCaptureKit, QuickTime screen recording,
    /// macOS screenshots). `.readOnly` (the default) lets capture see it. The
    /// window remains fully visible on the local display either way — this only
    /// affects what other parties / recordings see.
    private func applyHideFromScreenSharing(_ on: Bool) {
        window?.sharingType = on ? .none : .readOnly
    }
}
