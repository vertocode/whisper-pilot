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
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 52, height: 52)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
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
