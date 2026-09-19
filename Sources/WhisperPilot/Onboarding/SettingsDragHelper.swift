import AppKit
import SwiftUI

/// System Settings lists an app under Screen & System Audio Recording only after
/// the app has asked for that permission. When Whisper Pilot is missing from the
/// list, this small window lets the user drag the app into it (or use the +
/// button) instead of hunting for it. It never starts a capture or asks macOS
/// for anything, so it cannot raise a dialog.
@MainActor
final class SettingsDragHelper {
    static let shared = SettingsDragHelper()

    private static let size = CGSize(width: 430, height: 96)
    private var panel: NSPanel?
    private var activeObserver: NSObjectProtocol?

    func show() {
        close()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add Whisper Pilot"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DragHelperView(onDone: { [weak self] in self?.close() }))

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(DragHelperPlacement.frame(panel: Self.size, visibleScreen: visible), display: true)
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // Coming back to Whisper Pilot means the user is done in System Settings.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct DragHelperView: View {
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            DraggableAppIcon()
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.12)))
                .help("Drag this into the list in System Settings")
            VStack(alignment: .leading, spacing: 4) {
                Label("Drag Whisper Pilot into the list above", systemImage: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                Text("Or click + under the list and choose Whisper Pilot. Then switch it on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Done", action: onDone)
        }
        .padding(14)
        .frame(width: 430, height: 96)
    }
}

/// Plain AppKit on purpose: the panel can be dragged by its background, and a
/// SwiftUI drag on top of that moves the window instead of the icon.
private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView() }
    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

private final class AppIconDragView: NSView, NSDraggingSource {
    private let icon: NSImage = {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 128, height: 128)
        return image
    }()
    private var dragStarted = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
