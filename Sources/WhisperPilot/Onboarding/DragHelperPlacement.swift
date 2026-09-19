import CoreGraphics

/// Where the "drag Whisper Pilot into the list" window sits: the middle of the
/// screen, so the user sees right away that it opened in front of System
/// Settings. The window can be moved by its background if it covers something.
enum DragHelperPlacement {
    static func frame(panel: CGSize, visibleScreen: CGRect, margin: CGFloat = 12) -> CGRect {
        let x = visibleScreen.midX - panel.width / 2
        let y = visibleScreen.midY - panel.height / 2
        let clampedX = min(max(x, visibleScreen.minX + margin), max(visibleScreen.maxX - panel.width - margin, visibleScreen.minX + margin))
        let clampedY = min(max(y, visibleScreen.minY + margin), max(visibleScreen.maxY - panel.height - margin, visibleScreen.minY + margin))
        return CGRect(x: clampedX, y: clampedY, width: panel.width, height: panel.height)
    }
}
