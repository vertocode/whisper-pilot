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

    /// Sessions last used before the cutoff. Uses `lastUsedAt` because that is the date
    /// each row shows, and a session reopened last week is not old however long ago it
    /// was created. A session used exactly at the cutoff is kept.
    static func match(
        _ limit: SessionAgeLimit,
        in sessions: [SessionMeta],
        openSessions: Set<SessionID>,
        now: Date,
        calendar: Calendar = .current
    ) -> AgeMatch {
        let cutoff = limit.cutoff(from: now, calendar: calendar)
        // `distantPast` means the folder had no readable dates, so its age is unknown.
        let old = sessions.filter { $0.lastUsedAt < cutoff && $0.lastUsedAt != .distantPast }
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
        openSessions: () -> Set<SessionID>
    ) async -> Outcome {
        var outcome = Outcome()
        for session in sessions {
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
