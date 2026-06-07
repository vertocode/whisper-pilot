import AppKit

/// One connected display, for the screen-capture monitor picker in Settings and
/// for resolving which monitor `captureScreenJPEG` grabs. `id` is the
/// `CGDirectDisplayID` (a `UInt32`), which is what `SCDisplay.displayID` exposes,
/// so the two map directly.
struct ScreenInfo: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

/// Display enumeration helpers shared between the settings picker and the
/// coordinator's capture path. Lives outside the coordinator so the SwiftUI
/// settings view can list monitors without importing it.
enum ScreenEnumerator {
    /// All currently-connected displays in `NSScreen` order. Empty only if the
    /// process has no window server connection (shouldn't happen for a GUI app).
    static func connectedScreens() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return ScreenInfo(id: id, name: screen.localizedName)
        }
    }

    /// The display the pointer is currently on — our proxy for "the monitor the
    /// user is looking at" when capture is set to follow the current monitor.
    /// Falls back to the main screen, then `0` (which callers treat as "just use
    /// the first available display").
    static func currentPointerDisplayID() -> UInt32 {
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
           let id = displayID(of: screen) {
            return id
        }
        if let main = NSScreen.main, let id = displayID(of: main) {
            return id
        }
        return 0
    }

    /// Pulls the `CGDirectDisplayID` out of an `NSScreen`'s device description.
    static func displayID(of screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
