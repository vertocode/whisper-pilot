import Foundation

/// Picks which other installed copies of Whisper Pilot are older than the one
/// running, so the user can be offered to remove them.
enum OlderCopies {
    struct Copy: Equatable {
        let path: String
        let version: String

        /// Remembers "Not now" for this exact copy, so a newer old copy asks again.
        var dismissalKey: String { "\(path)|\(version)" }
    }

    static func find(installedVersion: String, currentPath: String, candidates: [Copy]) -> [Copy] {
        // Running from a disk image or a quarantined download: the copy in
        // /Applications may be the only permanent one, so leave it alone.
        guard !isTemporaryLocation(currentPath) else { return [] }
        return candidates.filter { copy in
            copy.path != currentPath
                && !isTemporaryLocation(copy.path)
                && !copy.path.contains("/.Trash/")
                && UpdateChecker.isVersion(installedVersion, newerThan: copy.version)
        }
    }

    private static func isTemporaryLocation(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }
}
