import CoreGraphics

/// Where the "drag Whisper Pilot into the list" window sits. It goes at the
/// bottom-centre of the screen: System Settings opens above it, and the list's
/// + button (bottom-left of System Settings) stays uncovered.
enum DragHelperPlacement {
    static func frame(panel: CGSize, visibleScreen: CGRect, margin: CGFloat = 12) -> CGRect {
        let x = visibleScreen.midX - panel.width / 2
        let clampedX = min(max(x, visibleScreen.minX + margin), max(visibleScreen.maxX - panel.width - margin, visibleScreen.minX + margin))
        return CGRect(x: clampedX, y: visibleScreen.minY + margin, width: panel.width, height: panel.height)
    }
}
