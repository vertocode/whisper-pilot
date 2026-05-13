import Combine
import Foundation

/// App-wide context applied to **every** session's AI prompt. Lives on disk at
/// `<App Support>/<bundle>/global-context.json` (one level above the per-session
/// folders) so it survives session deletes and is shared across sessions.
///
/// Single shared instance owned by `AppCoordinator`. The Sessions home page reads
/// and writes via a SwiftUI binding to `context`; `AppCoordinator.filteredSnapshot`
/// pulls the latest value when building prompts. Edits are persisted on a 400ms
/// debounce so a typing burst produces one disk write, not one per keystroke.
@MainActor
final class GlobalContextStore: ObservableObject {
    @Published var context: SessionContext = SessionContext()

    private var saver: AnyCancellable?
    private var pendingSave: DispatchWorkItem?
    /// Set during `loadFromDisk` so the just-loaded value doesn't immediately
    /// schedule a write-back (would be a no-op, but pointless I/O).
    private var isLoading: Bool = false

    init() {
        Task { [weak self] in
            let loaded = await SessionStore.shared.loadGlobalContext()
            await MainActor.run {
                guard let self else { return }
                self.isLoading = true
                self.context = loaded
                self.isLoading = false
                self.subscribeToChanges()
            }
        }
    }

    private func subscribeToChanges() {
        saver = $context
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                guard let self, !self.isLoading else { return }
                self.scheduleSave(newValue)
            }
    }

    private func scheduleSave(_ value: SessionContext) {
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            Task { await SessionStore.shared.saveGlobalContext(value) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Flush the pending debounced save synchronously. Used by `AppCoordinator`
    /// when shutting down so the user's last keystrokes don't disappear.
    func flush() async {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        let value = context
        await SessionStore.shared.saveGlobalContext(value)
    }
}
