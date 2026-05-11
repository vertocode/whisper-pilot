import SwiftUI

/// Small shared design tokens used across the overlay, sessions, and settings UI.
/// Centralized so density, rhythm, and corner-radius scale stay consistent without
/// scattering magic numbers through every view file. Kept intentionally minimal —
/// when in doubt, prefer SwiftUI's built-in `.font(.caption)` / `.body` / etc.
enum WP {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 14
    }

    /// Compact type scale for the dense overlay. macOS' built-in scale (17 pt body)
    /// is too large for an always-on-top panel that's competing with a video window.
    /// (Named `TextStyle`, not `Type`, because `Type` is a Swift reserved word that
    /// conflicts with the metatype `.Type` syntax.)
    enum TextStyle {
        static let micro = Font.system(size: 10, weight: .medium)
        static let tag = Font.system(size: 10, weight: .semibold).leading(.tight)
        static let label = Font.system(size: 11, weight: .medium)
        static let body = Font.system(size: 12)
        static let bodyEmphasized = Font.system(size: 12, weight: .medium)
        static let sectionHeader = Font.system(size: 11, weight: .semibold).leading(.tight)
    }
}

/// Compact rounded chip — used for badges, status pills, and toggle affordances.
/// Single source of truth so every chip in the app reads the same.
struct ChipStyle: ViewModifier {
    enum Tone {
        case neutral
        case accent
        case success
        case warning
        case danger
        case channel(Color)

        var foreground: Color {
            switch self {
            case .neutral: return .secondary
            case .accent: return .accentColor
            case .success: return .green
            case .warning: return .orange
            case .danger: return .red
            case .channel(let color): return color
            }
        }

        var fill: Color {
            switch self {
            case .neutral: return Color.primary.opacity(0.06)
            case .accent: return Color.accentColor.opacity(0.14)
            case .success: return Color.green.opacity(0.14)
            case .warning: return Color.orange.opacity(0.14)
            case .danger: return Color.red.opacity(0.14)
            case .channel(let color): return color.opacity(0.14)
            }
        }

        var stroke: Color {
            switch self {
            case .neutral: return Color.primary.opacity(0.08)
            case .accent: return Color.accentColor.opacity(0.28)
            case .success: return Color.green.opacity(0.28)
            case .warning: return Color.orange.opacity(0.28)
            case .danger: return Color.red.opacity(0.28)
            case .channel(let color): return color.opacity(0.28)
            }
        }
    }

    let tone: Tone
    var horizontalPadding: CGFloat = 7
    var verticalPadding: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(tone.foreground)
            .background(
                RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                    .fill(tone.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                    .strokeBorder(tone.stroke, lineWidth: 0.5)
            )
    }
}

extension View {
    func chip(_ tone: ChipStyle.Tone, horizontalPadding: CGFloat = 7, verticalPadding: CGFloat = 3) -> some View {
        modifier(ChipStyle(tone: tone, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding))
    }
}
