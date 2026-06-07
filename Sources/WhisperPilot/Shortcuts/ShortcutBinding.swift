import AppKit
import Foundation

/// Persistent representation of a global keyboard shortcut. `keyCode` matches
/// `NSEvent.keyCode` (the hardware-level virtual key); `modifiers` is the raw
/// value of an `NSEvent.ModifierFlags` mask (device-independent flags only).
/// Stored in UserDefaults as JSON so the format survives schema additions.
struct ShortcutBinding: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Human-readable label like "⌘⇧Z" for UI display.
    var displayLabel: String {
        var s = ""
        let flags = nsModifierFlags
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// Default for "toggle overlay visibility": ⌘⇧Z. Keycode 0x06 is Z on every
    /// Mac keyboard layout — keycodes are hardware positions, not characters.
    static let toggleOverlayDefault = ShortcutBinding(
        keyCode: 0x06,
        modifiers: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
    )

    /// Default for "answer what's on screen": ⌘⇧A. Keycode 0x00 is A on every
    /// Mac keyboard layout. Captures the current screen and asks the AI to answer
    /// whatever question is visible (multiple-choice or free text).
    static let answerScreenDefault = ShortcutBinding(
        keyCode: 0x00,
        modifiers: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
    )

    /// Maps a hardware key code to a printable label. Covers the common keys a
    /// user is likely to bind. Falls back to a numeric placeholder for the
    /// long tail (function keys past F12, JIS keys, etc.) so the UI still
    /// shows *something* even if we don't have a glyph for it.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"
        case 0x1D: return "0"
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}
