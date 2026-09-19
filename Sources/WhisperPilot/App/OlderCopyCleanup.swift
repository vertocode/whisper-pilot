import AppKit

/// After an update by DMG the old app can stay behind (opened from Downloads,
/// or copied next to the new one). This asks the user, once per copy, whether
/// to move it to the Trash. It never removes anything without a click.
@MainActor
enum OlderCopyCleanup {
    private static let dismissedKey = "olderCopy.dismissed"

    static func offerIfNeeded(defaults: UserDefaults = .standard) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let dismissed = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
        let running = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })

        let candidates: [OlderCopies.Copy] = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .compactMap { url in
                let resolved = url.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: resolved.path),
                      let version = Bundle(url: resolved)?.infoDictionary?["CFBundleShortVersionString"] as? String
                else { return nil }
                return OlderCopies.Copy(path: resolved.path, version: version)
            }

        let older = OlderCopies.find(
            installedVersion: AppInfo.version,
            currentPath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            candidates: candidates
        ).filter { !dismissed.contains($0.dismissalKey) && !running.contains($0.path) }

        for copy in older {
            switch ask(about: copy) {
            case .trash: trash(copy)
            case .notNow:
                defaults.set(Array(dismissed) + [copy.dismissalKey], forKey: dismissedKey)
            }
        }
    }

    private enum Answer { case trash, notNow }

    private static func ask(about copy: OlderCopies.Copy) -> Answer {
        let folder = (URL(fileURLWithPath: copy.path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let alert = NSAlert()
        alert.messageText = "An older Whisper Pilot is still on this Mac"
        alert.informativeText = "Version \(copy.version) is in \(folder). You are running version \(AppInfo.version). Moving the old one to the Trash keeps you from opening it by mistake. You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .trash : .notNow
    }

    private static func trash(_ copy: OlderCopies.Copy) {
        let url = URL(fileURLWithPath: copy.path)
        NSWorkspace.shared.recycle([url]) { _, error in
            guard let error else { return }
            wpWarn("Could not move the older copy to the Trash: \(error.localizedDescription)")
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Couldn't move the old version to the Trash"
                alert.informativeText = "\(error.localizedDescription)\n\nYou can drag it to the Trash yourself."
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "Close")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
