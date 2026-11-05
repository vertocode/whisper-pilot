import Foundation

/// How aggressively the queue translates. Tier-1 of the resource safety valve
/// flips this down rather than killing the feature outright — a non-native
/// speaker loses far more from captions vanishing than from them lagging.
enum TranslationMode: Sendable, Equatable {
    /// Steady state: in-progress (volatile) rows are translated on a stability
    /// debounce, so the translated column tracks speech within ~0.5 s.
    case partials
    /// Degraded: only committed rows are translated. Drops the call rate by
    /// roughly 5-10x. Engaged by `AppCoordinator.engageTier1`.
    case finalsOnly
}

/// Owns *when* a transcript row gets translated. The engine itself
/// (`TranslationProviding`) is deliberately dumb; every scheduling concern —
/// debouncing, ordering, degradation, lifecycle — lives here.
///
/// ## Why this is snapshot-driven rather than update-driven
///
/// `TranscriptBuffer` mutates rows *after* they are committed: a containment
/// merge rewrites the previous final's text, and a roll-up appends the next
/// utterance onto it (up to 600 characters). A translation pinned to a row at
/// commit time therefore goes stale while the row is still on screen.
///
/// Rather than hooking both mutation paths, the queue diffs the buffer snapshot
/// the coordinator *already computes* for its UI publish. Any row whose text no
/// longer matches what we last translated is simply re-queued. Merge, roll-up,
/// and any future rewrite rule are handled without knowing they exist.
///
/// ## Ordering
///
/// Translations are async and can land out of order — a short partial issued
/// later can beat a long one issued earlier. Every row carries a monotonic
/// generation; a response whose generation is stale is dropped. Without this
/// the translated column intermittently shows the wrong sentence.
actor TranslationQueue {
    /// How long a volatile row's text must stop changing before we translate
    /// it. Measured translation cost is ~34 ms, so this is not a throughput
    /// guard — it exists so the translated column rewrites at clause pauses
    /// instead of mid-word. Translating a prefix does not yield a prefix of the
    /// translation ("I don't think we" → "Eu não acho que nós", but "I don't
    /// think we should" → "Eu não acho que deveríamos"), so every re-issue is a
    /// visible rewrite, not an append.
    static let partialDebounce: Duration = .milliseconds(400)

    /// Per-row bookkeeping. `translatedSource` is the exact text we last
    /// produced a translation for, which is what makes the diff cheap and makes
    /// re-translation happen exactly when a row actually changed.
    private struct RowState {
        var translatedSource: String?
        var scheduledSource: String?
        var generation: Int = 0
        /// Runs the debounce sleep and then the translation. Only cancelled
        /// while `inFlight` is false, so a started translation is never aborted.
        var debounceTask: Task<Void, Never>?
        /// True from the moment the engine call starts until it returns. At most
        /// one call per row is ever in flight.
        var inFlight = false
        /// Whether the latest scheduled text came from a committed row, which
        /// decides if its follow-up call skips the debounce.
        var scheduledIsFinal = false
    }

    private let provider: any TranslationProviding
    /// Write-back into `TranscriptBuffer.setTranslation`. Injected rather than
    /// referenced directly so this actor stays testable without a buffer.
    private let onTranslated: @Sendable (UUID, String) async -> Void

    private var mode: TranslationMode = .partials
    private var rows: [UUID: RowState] = [:]
    /// Rows that existed before translation was switched on. Never translated —
    /// enabling mid-session applies from that point forward, so flipping the
    /// toggle can't fire a burst of up to 150 calls and trip the very safety
    /// valve this feature hooks into.
    private var baseline: Set<UUID> = []
    private var isStopped = false

    /// Called once when this many translations in a row fail, so a broken
    /// engine can be surfaced instead of leaving captions silently empty.
    private var onPersistentFailure: (@Sendable (String) async -> Void)?
    private var consecutiveFailures = 0
    private static let persistentFailureThreshold = 3

    /// Bound on tracked rows so a long session can't grow this map without
    /// limit. Mirrors `TranscriptBuffer.maxFinals`; rows evicted from the
    /// buffer can never reappear in a snapshot, so dropping their state is safe.
    private static let maxTrackedRows = 200

    init(
        provider: any TranslationProviding,
        onTranslated: @escaping @Sendable (UUID, String) async -> Void
    ) {
        self.provider = provider
        self.onTranslated = onTranslated
    }

    func setPersistentFailureHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        onPersistentFailure = handler
    }

    /// Records the rows already on screen as untranslatable. Call once, right
    /// after construction, with the current buffer snapshot.
    func markBaseline(_ segments: [TranscriptSegment]) {
        baseline = Set(segments.map(\.id))
    }

    func setMode(_ newMode: TranslationMode) {
        guard mode != newMode else { return }
        mode = newMode
        // Dropping to finals-only must also abandon debounces already in
        // flight for volatile rows, or the degradation is delayed by up to one
        // debounce window per row.
        if newMode == .finalsOnly {
            for (id, var state) in rows where state.debounceTask != nil && !state.inFlight {
                state.debounceTask?.cancel()
                state.debounceTask = nil
                state.scheduledSource = nil
                rows[id] = state
            }
        }
    }

    /// One throwaway translation so the first real caption doesn't pay
    /// model-load cost (~834 ms measured, versus ~34 ms steady state).
    func prewarm() async {
        await provider.prewarm()
    }

    /// Feed the buffer snapshot the coordinator just published. Rows that are
    /// new, or whose text changed since we last translated them, get queued.
    ///
    /// Only the system channel is considered: you already know what you said,
    /// so translating your own microphone lines doubles the cost for the half
    /// of the transcript with the least payoff.
    func ingest(_ segments: [TranscriptSegment]) {
        guard !isStopped else { return }

        var live: Set<UUID> = []
        for segment in segments where segment.channel == .system {
            live.insert(segment.id)
            guard !baseline.contains(segment.id) else { continue }

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // In degraded mode a volatile row is ignored entirely. It will be
            // picked up the moment it commits, because committing changes
            // `isFinal` and usually the text too.
            if mode == .finalsOnly && !segment.isFinal { continue }

            var state = rows[segment.id] ?? RowState()
            // Already translated exactly this text, or already scheduled to.
            if state.translatedSource == text || state.scheduledSource == text {
                rows[segment.id] = state
                continue
            }

            state.scheduledSource = text
            state.scheduledIsFinal = segment.isFinal
            state.generation += 1

            // A translation already running is left alone: cancelling it would
            // abort the engine call, and a long row that keeps growing would
            // never finish. The latest text is picked up when it returns.
            if !state.inFlight {
                state.debounceTask?.cancel()
                // Finals skip the debounce: their text is settled the moment it
                // commits, and waiting only adds lag. When a roll-up later appends
                // to that same row the text changes, which re-enters this path and
                // re-translates — exactly the intended behavior.
                state.debounceTask = makeTask(
                    id: segment.id, text: text, generation: state.generation,
                    delay: segment.isFinal ? nil : Self.partialDebounce
                )
            }
            rows[segment.id] = state
        }

        pruneRows(keeping: live)
    }

    /// Cancels everything in flight and forgets all per-row state. Called on
    /// session teardown and when the user turns the feature off mid-session.
    func stop() {
        isStopped = true
        for state in rows.values { state.debounceTask?.cancel() }
        rows.removeAll()
        baseline.removeAll()
    }

    // MARK: - Internals

    private func makeTask(id: UUID, text: String, generation: Int, delay: Duration?) -> Task<Void, Never> {
        Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.performTranslation(id: id, text: text, generation: generation)
        }
    }

    private func performTranslation(id: UUID, text: String, generation: Int) async {
        guard !isStopped else { return }
        // Bail if a newer revision of this row was scheduled while we waited
        // out the debounce.
        guard var started = rows[id], started.generation == generation else { return }
        started.inFlight = true
        rows[id] = started

        let translated: String
        do {
            translated = try await provider.translate(text)
        } catch {
            // Our own stop()/prune cancelling the call is not an engine failure.
            if Task.isCancelled || isStopped || error is CancellationError {
                if var state = rows[id] {
                    state.inFlight = false
                    rows[id] = state
                }
                return
            }
            // A failure is not worth a user-visible error: the row simply stays
            // untranslated and the next revision tries again. Logged once at
            // debug volume rather than per line, which on a bad pair would be
            // several messages a second.
            wpWarn("[Translation] failed for a \(text.count)-char line: \(error)")
            if var state = rows[id] {
                state.inFlight = false
                if state.generation == generation {
                    state.scheduledSource = nil
                    state.debounceTask = nil
                    rows[id] = state
                } else {
                    rows[id] = state
                    scheduleFollowUp(id: id)
                }
            }
            consecutiveFailures += 1
            if consecutiveFailures == Self.persistentFailureThreshold, !isStopped {
                await onPersistentFailure?(error.localizedDescription)
            }
            return
        }
        consecutiveFailures = 0

        // Re-check after the await: the session may have been torn down, or the
        // row pruned, while the engine was working.
        guard !isStopped, var state = rows[id] else { return }
        state.inFlight = false
        state.translatedSource = text
        let isCurrent = state.generation == generation
        if isCurrent {
            state.scheduledSource = nil
            state.debounceTask = nil
        }
        rows[id] = state
        // If the row moved on meanwhile this is an interim translation of the
        // older text: better than an empty column, and replaced by the
        // follow-up. No newer result can exist yet, since only one call per row
        // runs at a time. The follow-up is scheduled before the write-back
        // suspends, so a concurrent ingest sees it.
        if !isCurrent { scheduleFollowUp(id: id) }
        await onTranslated(id, translated)
    }

    /// Starts the single follow-up call for the latest text of a row whose
    /// previous call finished while newer text was already waiting. However many
    /// updates arrived during the flight, only the latest is translated.
    private func scheduleFollowUp(id: UUID) {
        guard !isStopped, var state = rows[id], !state.inFlight,
              let latest = state.scheduledSource else { return }
        if latest == state.translatedSource || (mode == .finalsOnly && !state.scheduledIsFinal) {
            state.scheduledSource = nil
            state.debounceTask = nil
            rows[id] = state
            return
        }
        state.debounceTask = makeTask(
            id: id, text: latest, generation: state.generation,
            delay: state.scheduledIsFinal ? nil : Self.partialDebounce
        )
        rows[id] = state
    }

    /// Drops state for rows that have fallen out of the buffer, and enforces the
    /// tracked-row ceiling. `keeping` is the set of ids present in the snapshot
    /// we just processed.
    private func pruneRows(keeping live: Set<UUID>) {
        guard rows.count > Self.maxTrackedRows else { return }
        for (id, state) in rows where !live.contains(id) {
            state.debounceTask?.cancel()
            rows.removeValue(forKey: id)
        }
        // Baseline ids are only meaningful while those rows are on screen.
        baseline.formIntersection(live)
    }
}
