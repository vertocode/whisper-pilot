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
