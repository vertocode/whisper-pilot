import Foundation

/// Decides which copy of the app keeps running when two share a bundle id.
enum SingleInstance {
    struct Candidate: Equatable {
        let pid: Int32
        let launchDate: Date?
    }

    /// The oldest copy wins, so two copies started at the same moment don't both
    /// quit. A copy with no launch date loses; equal dates fall back to the lower pid.
    static func winner(among candidates: [Candidate]) -> Candidate? {
        candidates.min { a, b in
            switch (a.launchDate, b.launchDate) {
            case let (x?, y?): return x != y ? x < y : a.pid < b.pid
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.pid < b.pid
            }
        }
    }

    /// The other copy this one should hand over to, or nil if this one keeps running.
    static func copyToHandOverTo(me: Candidate, others: [Candidate]) -> Candidate? {
        guard let winner = winner(among: others + [me]), winner != me else { return nil }
        return winner
    }
}
