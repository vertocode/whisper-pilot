import AppKit
import SwiftUI

/// SwiftUI field that captures a keyboard shortcut. Click it to start recording,
/// press a modifier-plus-key combo to set it, press Escape to cancel without
/// changing the binding. Refuses combos with no modifier — bare keystrokes
/// would shadow normal typing globally and almost certainly aren't what the
/// user wants.
struct KeyRecorderField: NSViewRepresentable {
    @Binding var shortcut: ShortcutBinding

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.currentShortcut = shortcut
        view.onChange = { newShortcut in
            DispatchQueue.main.async { self.shortcut = newShortcut }
        }
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.currentShortcut = shortcut
        nsView.needsDisplay = true
    }
}

final class KeyRecorderNSView: NSView {
    var currentShortcut: ShortcutBinding?
    var onChange: ((ShortcutBinding) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 26)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Escape leaves the field without modifying the binding.
        if event.keyCode == 0x35 {
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifier = mods.contains(.command) || mods.contains(.shift) || mods.contains(.option) || mods.contains(.control)
        guard hasModifier else {
            // Beep and ignore — recording stays active so the user can try again.
            NSSound.beep()
            return
        }
        let updated = ShortcutBinding(keyCode: event.keyCode, modifiers: mods.rawValue)
        currentShortcut = updated
        onChange?(updated)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let label: String
        if isRecording {
            label = "Press shortcut…"
        } else {
            label = currentShortcut?.displayLabel ?? "—"
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let bg = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.unemphasizedSelectedContentBackgroundColor
        bg.setFill()
        path.fill()
        let border = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }
}
