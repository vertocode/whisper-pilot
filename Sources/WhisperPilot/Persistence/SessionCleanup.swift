import Foundation

/// The age choices in "Delete old sessions".
enum SessionAgeLimit: Int, CaseIterable, Identifiable, Sendable {
    case oneMonth = 1
    case threeMonths = 3
    case sixMonths = 6
    case oneYear = 12

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneMonth: return "Older than 1 month"
        case .threeMonths: return "Older than 3 months"
        case .sixMonths: return "Older than 6 months"
        case .oneYear: return "Older than 1 year"
        }
    }

    /// If the date can't be worked out, the cutoff is so early that nothing counts as old.
    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: -rawValue, to: now) ?? .distantPast
    }
}

/// Picks and deletes many sessions at once. Works from `SessionMeta` alone, so counting
/// matches never reads a transcript.
enum SessionCleanup {
    struct AgeMatch: Equatable {
        var sessions: [SessionMeta]
        /// A session in use, when it is old enough to match but has to stay.
        var keptOpenSession: SessionMeta?
    }

    struct Outcome {
        var deleted: [SessionID] = []
        var skippedOpen: [SessionMeta] = []
        var failed: [(session: SessionMeta, error: Error)] = []
    }

    /// Sessions whose last activity was before the cutoff. Uses `lastUsedAt` because that
    /// is the date each row shows. It moves on new transcript lines, chat turns, and model
    /// changes, so reopening a session just to read it usually leaves it as old as it was.
    /// A session active exactly at the cutoff is kept.
    static func match(
        _ limit: SessionAgeLimit,
        in sessions: [SessionMeta],
        openSessions: Set<SessionID>,
        now: Date,
        calendar: Calendar = .current
    ) -> AgeMatch {
        let cutoff = limit.cutoff(from: now, calendar: calendar)
        // Without readable dates the age is only a guess, and a guess must not delete anything.
        let old = sessions.filter { $0.hasReadableDates && $0.lastUsedAt < cutoff }
        return AgeMatch(
            sessions: old.filter { !openSessions.contains($0.id) },
            keptOpenSession: old.first { openSessions.contains($0.id) }
        )
    }

    /// Deletes one session per store call, so a long batch never blocks a live session
    /// from saving its transcript. Open sessions are checked before every deletion
    /// because the user can open one while this runs.
    @MainActor
    static func delete(
        _ sessions: [SessionMeta],
        from store: SessionStore,
        openSessions: () -> Set<SessionID>,
        onProgress: (Int) -> Void = { _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        for (index, session) in sessions.enumerated() {
            defer { onProgress(index + 1) }
            if openSessions().contains(session.id) {
                outcome.skippedOpen.append(session)
                continue
            }
            do {
                try await store.deleteSession(session.id)
                outcome.deleted.append(session.id)
            } catch {
                outcome.failed.append((session, error))
            }
        }
        return outcome
    }

    /// Sessions the user asked to open that aren't the current session yet. Counted per
    /// session because the same one can be opened twice before the first open finishes.
    struct OpeningSessions {
        private var counts: [SessionID: Int] = [:]

        var ids: Set<SessionID> { Set(counts.keys) }

        mutating func begin(_ id: SessionID) {
            counts[id, default: 0] += 1
        }

        mutating func end(_ id: SessionID) {
            guard let count = counts[id] else { return }
            counts[id] = count > 1 ? count - 1 : nil
        }
    }

    static func countLabel(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s")"
    }
}

/// Keeps quick back-to-back session opens from mixing. Every open gets a number, and
/// an older open stops at its next check once a newer one has been asked for.
struct SessionOpenGate {
    private(set) var latest = 0
    /// Set while an open has switched to a session but not finished loading it. An open
    /// that stops early leaves it set, so opening that session again loads it fully.
    private var halfOpened: SessionID?

    mutating func begin() -> Int {
        latest += 1
        return latest
    }

    func isCurrent(_ open: Int) -> Bool { open == latest }

    func needsOpen(_ id: SessionID, current: SessionID?) -> Bool {
        current != id || halfOpened == id
    }

    mutating func switched(to id: SessionID) { halfOpened = id }

    mutating func finished() { halfOpened = nil }
}
