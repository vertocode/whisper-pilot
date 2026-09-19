import Foundation

enum MenuEntry: Equatable {
    case finishSetup
    case toggleListening(running: Bool)
    case showOverlay
    case sessions
    case settings
    case separator
    case about
    case quit
}

/// Which entries the menu bar menu shows. While a permission the app needs is
/// missing, listening and sessions cannot work, so only setup, Settings, About
/// and Quit are offered.
enum MenuLayout {
    static func entries(needsSetup: Bool, listeningActive: Bool) -> [MenuEntry] {
        let head: [MenuEntry] = needsSetup
            ? [.finishSetup, .separator, .settings]
            : [.toggleListening(running: listeningActive), .showOverlay, .separator, .sessions, .settings]
        return head + [.separator, .about, .quit]
    }
}
