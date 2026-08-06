import AppKit
import SwiftUI

/// Where the overlay window anchors on its current screen. Size is controlled
/// separately (width/height fractions); this only decides the corner/edge the
/// window hugs once it has a size.
enum OverlayPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case topLeft, topCenter, topRight
    case left, center, right
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    /// Computes the window origin (AppKit bottom-left coordinate space) that
    /// anchors a window of `size` to this position within `visible`, leaving
    /// `inset` points of breathing room against screen edges.
    func origin(in visible: NSRect, size: NSSize, inset: CGFloat) -> NSPoint {
        let left = visible.minX + inset
        let right = visible.maxX - size.width - inset
        let centerX = visible.midX - size.width / 2
        let top = visible.maxY - size.height - inset
        let bottom = visible.minY + inset
        let centerY = visible.midY - size.height / 2

        switch self {
        case .topLeft:      return NSPoint(x: left,    y: top)
        case .topCenter:    return NSPoint(x: centerX, y: top)
        case .topRight:     return NSPoint(x: right,   y: top)
        case .left:         return NSPoint(x: left,    y: centerY)
        case .center:       return NSPoint(x: centerX, y: centerY)
        case .right:        return NSPoint(x: right,   y: centerY)
        case .bottomLeft:   return NSPoint(x: left,    y: bottom)
        case .bottomCenter: return NSPoint(x: centerX, y: bottom)
        case .bottomRight:  return NSPoint(x: right,   y: bottom)
        }
    }
}

/// Concrete appearance/layout values a non-custom mode applies. `.custom` has no
/// preset — it's whatever the user last set by hand.
struct OverlayLayoutPreset: Sendable {
    var widthFraction: Double
    var heightFraction: Double
    var position: OverlayPosition
    var showTranscript: Bool
    var showExtraActions: Bool
    var backgroundOpacity: Double
    /// "" = use the system default (`.primary`). Otherwise a `#RRGGBB` string.
    var textColorHex: String
    /// Denser padding + smaller controls so a short window stays usable. On for
    /// the small modes (Interview / Compact), off for the roomy ones.
    var compactChrome: Bool
}

/// A named overlay layout. Selecting one fills every individual appearance
/// setting from its `preset`; editing any of those settings afterward flips the
/// active mode to `.custom` so the user's tweaks aren't silently relabeled as a
/// canned mode.
enum OverlayLayoutMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Tiny window at the top showing just the AI conversation + Help AI — for
    /// when the screen is dominated by someone else's share / camera grid.
    case interview
    /// Small, transcript hidden, tucked top-right — quick glanceable answers.
    case compact
    /// Half-screen, everything visible — the balanced default.
    case standard
    /// A third of the monitor's width, full height, hugging the right edge —
    /// a persistent side panel that leaves two thirds of the screen for the
    /// meeting. The default for fresh installs.
    case sidebar
    /// Half the monitor's width, full height, hugging the right edge — split your
    /// big monitor and keep every control in reach.
    case focus
    /// User-tuned. No canonical preset.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .interview: return "Interview"
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .sidebar: return "Sidebar"
        case .focus: return "Focus (split)"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .interview: return "Tiny window up top — AI answers and Help AI only. For when their screen/cams own the display."
        case .compact: return "Small and tucked away, transcript hidden. Glanceable AI answers without taking over."
        case .standard: return "Half-screen with transcript and every action button. The balanced default."
        case .sidebar: return "A third of the screen wide, full height, on the right edge. A persistent side panel next to your meeting."
        case .focus: return "Half your monitor's width, full height. Split the screen and keep everything in reach."
        case .custom: return "Your own tuned layout. Pick a mode above to start from a preset."
        }
    }

    var icon: String {
        switch self {
        case .interview: return "person.crop.rectangle"
        case .compact: return "rectangle.compress.vertical"
        case .standard: return "rectangle.split.2x1"
        case .sidebar: return "sidebar.right"
        case .focus: return "rectangle.righthalf.inset.filled"
        case .custom: return "slider.horizontal.3"
        }
    }

    var preset: OverlayLayoutPreset? {
        switch self {
        case .interview:
            // Wide enough to read an answer comfortably, but deliberately short —
            // just the AI reply + composer up top, out of the way of their share.
            return OverlayLayoutPreset(widthFraction: 0.38, heightFraction: 0.22, position: .topCenter,
                                       showTranscript: false, showExtraActions: false,
                                       backgroundOpacity: 0.96, textColorHex: "", compactChrome: true)
        case .compact:
            return OverlayLayoutPreset(widthFraction: 0.30, heightFraction: 0.40, position: .topRight,
                                       showTranscript: false, showExtraActions: false,
                                       backgroundOpacity: 0.90, textColorHex: "", compactChrome: true)
        case .standard:
            return OverlayLayoutPreset(widthFraction: 0.50, heightFraction: 0.52, position: .topRight,
                                       showTranscript: true, showExtraActions: true,
                                       backgroundOpacity: 0.88, textColorHex: "", compactChrome: false)
        case .sidebar:
            return OverlayLayoutPreset(widthFraction: 1.0 / 3.0, heightFraction: 1.0, position: .right,
                                       showTranscript: true, showExtraActions: true,
                                       backgroundOpacity: 0.92, textColorHex: "", compactChrome: false)
        case .focus:
            return OverlayLayoutPreset(widthFraction: 0.50, heightFraction: 0.97, position: .right,
                                       showTranscript: true, showExtraActions: true,
                                       backgroundOpacity: 0.94, textColorHex: "", compactChrome: false)
        case .custom:
            return nil
        }
    }
}

/// How the source transcript and its translation are arranged in a transcript
/// row when live translation is on.
enum TranslationLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Side by side when the lane is wide enough, stacked when it isn't.
    case auto
    /// Always two columns, however narrow the lane gets.
    case sideBySide
    /// Always source on top, translation beneath.
    case stacked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .sideBySide: return "Side by side"
        case .stacked: return "Stacked"
        }
    }

    var summary: String {
        switch self {
        case .auto: return "Side by side when the overlay is wide enough, stacked when it's narrow. Recommended."
        case .sideBySide: return "Always two columns. In a narrow overlay each column gets very little room."
        case .stacked: return "Always source on top, translation underneath. Full width for both."
        }
    }

    /// Minimum text-region width (points) at which `.auto` chooses two columns.
    ///
    /// Derived from the shipped presets: the default Sidebar layout is a third
    /// of the screen, which leaves roughly 428 pt for text after the channel
    /// chip — about 34 characters per column once split, and translations run
    /// 15-25% longer than English so the translated side wraps even harder.
    /// Standard and Focus are half-screen, leaving ~680 pt, which splits
    /// comfortably. This threshold sits between the two.
    static let sideBySideMinimumWidth: CGFloat = 440

    /// Fraction of the row given to the *source* text when side by side. Under
    /// half because the translation is reliably the longer of the two.
    static let sourceWidthFraction: CGFloat = 0.45

    func resolved(forTextWidth width: CGFloat) -> TranslationLayout {
        switch self {
        case .auto:
            return width >= Self.sideBySideMinimumWidth ? .sideBySide : .stacked
        case .sideBySide, .stacked:
            return self
        }
    }
}

/// Hex <-> SwiftUI/AppKit color helpers for the overlay text-color setting. Kept
/// tiny and dependency-free — only `#RRGGBB` is supported, which is all the
/// settings palette needs.
enum OverlayColor {
    /// A small, meeting-friendly palette offered in Settings. Empty hex = default.
    static let palette: [(name: String, hex: String)] = [
        ("Default", ""),
        ("White", "#FFFFFF"),
        ("Soft yellow", "#FFE08A"),
        ("Mint", "#9BE8B6"),
        ("Sky", "#8FC9FF"),
        ("Rose", "#FFA8B6")
    ]

    static func color(fromHex hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#"), trimmed.count == 7 else { return nil }
        let scanner = Scanner(string: String(trimmed.dropFirst()))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

/// Environment channel for the user's overlay text color. `nil` = use `.primary`.
/// Threaded from `OverlayView` so deep child views (message bubbles, transcript
/// lines) can honor the setting without each taking a `SettingsStore` dependency.
private struct OverlayTextColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var overlayTextColor: Color? {
        get { self[OverlayTextColorKey.self] }
        set { self[OverlayTextColorKey.self] = newValue }
    }
}

/// Environment channel for the active translation layout. `nil` means "don't
/// render translations at all" — either the feature is off or no target is
/// configured. Threaded from `OverlayView` so `TranscriptRow` doesn't need a
/// `SettingsStore` dependency, matching how text color and compact density are
/// already passed down.
///
/// Note this is the *user's* setting, still possibly `.auto`; the row resolves
/// it against the measured lane width.
private struct TranslationLayoutKey: EnvironmentKey {
    static let defaultValue: TranslationLayout? = nil
}

extension EnvironmentValues {
    var translationLayout: TranslationLayout? {
        get { self[TranslationLayoutKey.self] }
        set { self[TranslationLayoutKey.self] = newValue }
    }
}

/// Environment flag for the overlay's compact-chrome density. When true, deep
/// child views (message bubbles, etc.) tighten their padding so a short window
/// fits more. Threaded from `OverlayView`.
private struct OverlayCompactKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var overlayCompact: Bool {
        get { self[OverlayCompactKey.self] }
        set { self[OverlayCompactKey.self] = newValue }
    }
}
