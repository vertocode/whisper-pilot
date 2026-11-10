import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    private static let persistenceEpoch = Date(timeIntervalSince1970: 1_000_000)

    private static func finalUpdate(
        _ text: String,
        id: UUID = UUID(),
        channel: AudioChannel = .system,
        at seconds: TimeInterval,
        isFinal: Bool = true
    ) -> TranscriptUpdate {
        TranscriptUpdate(
            id: id,
            text: text,
            isFinal: isFinal,
            channel: channel,
            timestamp: persistenceEpoch.addingTimeInterval(seconds)
        )
    }

    static func runTranscriptPersistenceQueueSuite() async {
        let first = "This is the first complete sentence here."
        let second = "Now a different and separate thought follows."
        let third = "Finally the last speaker wraps everything up."

        await suite("TranscriptPersistenceQueue: finals close together") {
            var queue = TranscriptPersistenceQueue()
            let p = finalUpdate(first, at: 0)
            let u1 = finalUpdate(second, at: 0.1)
            let u2 = finalUpdate(third, at: 0.2)

            await expect(queue.accept(p) == nil, "first line waits for the next utterance")
            // No write happens between these two calls, like two finals landing
            // while the disk write is still waiting.
            let afterU1 = queue.accept(u1)
            let afterU2 = queue.accept(u2)
            await expect(afterU1?.id == p.id && afterU1?.text == first, "first new utterance releases the old line")
            await expect(afterU2?.id == u1.id && afterU2?.text == second, "second new utterance releases the middle line, not the old one again")
            let drained = queue.drain()
            await expect(drained.map(\.id) == [u2.id], "newest line is still pending")
            await expect(queue.drain().isEmpty, "draining twice writes nothing more")
        }

        await suite("TranscriptPersistenceQueue: merge rules") {
            var queue = TranscriptPersistenceQueue()
            let id = UUID()
            _ = queue.accept(finalUpdate("We should ship", id: id, at: 0))
            await expect(queue.accept(finalUpdate("We should ship this on Friday.", id: id, at: 1)) == nil,
                         "same id grows in place")
            await expect(queue.accept(finalUpdate("We should ship", id: id, at: 2)) == nil,
                         "same-id fragment stays in place")
            await expect(queue.drain().map(\.text) == ["We should ship this on Friday."],
                         "fragment did not clobber the fuller text")

            var duplicates = TranscriptPersistenceQueue()
            let natural = finalUpdate("hello there everyone on the call today", at: 1)
            _ = duplicates.accept(finalUpdate("hello there everyone", at: 0))
            await expect(duplicates.accept(natural) == nil, "containment duplicate under a new id merges")
            let merged = duplicates.drain()
            await expect(merged.map(\.id) == [natural.id] && merged.map(\.text) == [natural.text],
                         "merged line keeps the newer id and the fuller text")

            var rollUp = TranscriptPersistenceQueue()
            _ = rollUp.accept(finalUpdate("and so we are going", at: 0))
            await expect(rollUp.accept(finalUpdate("to improve image loading", at: 1)) == nil,
                         "continuation rolls up instead of releasing a fragment")
            await expect(rollUp.drain().map(\.text) == ["and so we are going to improve image loading"],
                         "rolled-up line joins both pieces")
        }

        await suite("TranscriptPersistenceQueue: lines already written") {
            var queue = TranscriptPersistenceQueue()
            let id = UUID()
            _ = queue.accept(finalUpdate(first, id: id, at: 0))
            _ = queue.drain()
            await expect(queue.accept(finalUpdate(first + " And more.", id: id, at: 1)) == nil,
                         "late re-final of a written id is ignored")
            await expect(queue.accept(finalUpdate(first, at: 2)) == nil,
                         "containment duplicate inside the window is ignored")
            await expect(queue.drain().isEmpty, "neither one is queued for writing")

            _ = queue.accept(finalUpdate(first, at: TranscriptDedup.mergeWindowSeconds + 1))
            await expect(queue.drain().map(\.text) == [first], "a genuine repeat later on is kept")

            _ = queue.accept(finalUpdate(second, id: id, at: 100))
            _ = queue.drain()
            queue.forgetPersistedLines()
            _ = queue.accept(finalUpdate(second, id: id, at: 101))
            await expect(queue.drain().map(\.id) == [id], "a new session's file starts with no memory")
        }

        await suite("TranscriptPersistenceQueue: open line at stop") {
            var queue = TranscriptPersistenceQueue()
            let previous = finalUpdate(first, at: 0)
            let open = finalUpdate(second, at: 5)
            _ = queue.accept(previous)

            // Stop takes the open line directly, and the same line also comes
            // through the transcript stream.
            let released = queue.accept(open)
            await expect(released?.id == previous.id, "open line releases the finished line before it")
            await expect(queue.accept(open) == nil, "the stream's copy before the flush adds nothing")
            let drained = queue.drain()
            await expect(drained.map(\.id) == [open.id] && drained.map(\.text) == [second],
                         "the flush writes the open line once")

            await expect(queue.accept(open) == nil, "the stream's copy after the flush adds nothing")
            await expect(queue.accept(finalUpdate(second + " Plus words decoded later.", id: open.id, at: 6)) == nil,
                         "the engine's last final for that id adds nothing")
            await expect(queue.drain().isEmpty, "nothing is left to write twice")
        }

        await suite("TranscriptPersistenceQueue: open line on both channels at stop") {
            var queue = TranscriptPersistenceQueue()
            let mic = finalUpdate(first, channel: .microphone, at: 2)
            let system = finalUpdate(second, channel: .system, at: 1)
            _ = queue.accept(mic)
            _ = queue.accept(system)
            await expect(queue.drain().map(\.id) == [system.id, mic.id], "both channels keep their open line")
        }

        await suite("TranscriptPersistenceQueue: channels and filtering") {
            var queue = TranscriptPersistenceQueue()
            let mic = finalUpdate(first, channel: .microphone, at: 0)
            let system = finalUpdate(second, channel: .system, at: 1)
            await expect(queue.accept(system) == nil, "one channel does not release the other")
            await expect(queue.accept(mic) == nil, "other channel holds its own line")
            await expect(queue.drain().map(\.id) == [mic.id, system.id], "drain is oldest first across channels")

            await expect(queue.accept(finalUpdate("a partial", at: 2, isFinal: false)) == nil, "partial is ignored")
            await expect(queue.accept(finalUpdate("   ", at: 3)) == nil, "blank final is ignored")
            await expect(queue.drain().isEmpty, "neither one becomes a line")
        }
    }
}
