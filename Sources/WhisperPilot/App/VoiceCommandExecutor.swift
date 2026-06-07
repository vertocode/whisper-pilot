import AppKit
import Foundation

/// Executes the system-action side of voice commands. Deliberately tiny surface:
/// launch an app by name, open an http(s) URL. No shell access — a misheard
/// command can at worst open the wrong app or a wrong search page.
enum VoiceCommandExecutor {
    /// Launches an app via `/usr/bin/open -a`, which resolves human names
    /// ("Google Chrome", "Safari") against /Applications and the system app
    /// folders — much more forgiving than bundle-identifier lookup for names
    /// coming out of speech recognition.
    static func openApp(named name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Opens an http(s) URL in the default browser. Non-web schemes are
    /// rejected — the interpreter should never produce them, but the model's
    /// output is untrusted input.
    static func openURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return NSWorkspace.shared.open(url)
    }
}
