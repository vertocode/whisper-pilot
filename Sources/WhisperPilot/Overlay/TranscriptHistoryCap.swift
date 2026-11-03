import Foundation

enum TranscriptHistoryCap {
    /// The full transcript is saved to disk. This list only feeds the scroll-back
    /// view, so a very long meeting must not keep every line in memory.
    static let limit = 2_000

    /// Keeps the newest `limit` items.
    static func capped<T>(_ items: [T], limit: Int = TranscriptHistoryCap.limit) -> [T] {
        guard limit >= 0, items.count > limit else { return items }
        return Array(items.suffix(limit))
    }
}
