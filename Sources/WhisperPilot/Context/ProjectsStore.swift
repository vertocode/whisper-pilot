import Combine
import Foundation

/// In-memory list of projects for the UI and the prompt builder, saved to disk through
/// `ProjectStorage`. Edits to instructions and files save on a short debounce, like
/// `GlobalContextStore`, so typing doesn't write on every keystroke.
@MainActor
final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var isLoaded = false

    private let storage: ProjectStorage
    private var pendingSave: DispatchWorkItem?
    /// Saves run one after another so an older snapshot can never land after a newer one.
    private var saveChain: Task<Void, Never>?
    /// Set once the user changes something. If that happens before the first disk
    /// load lands, the load is merged under the edit instead of replacing it.
    private var hasLocalEdit = false

    private var loadTask: Task<Void, Never>?

    init(storage: ProjectStorage = .shared) {
        self.storage = storage
        loadTask = Task { [weak self] in
            let loaded = await storage.load()
            await MainActor.run { self?.applyLoaded(loaded) }
        }
    }

    private func applyLoaded(_ loaded: [Project]) {
        if hasLocalEdit {
            let known = Set(projects.map(\.id))
            projects.append(contentsOf: loaded.filter { !known.contains($0.id) })
        } else {
            projects = loaded
        }
        projects = Self.sorted(projects)
        isLoaded = true
        if hasLocalEdit { saveNow() }
    }

    static func sorted(_ projects: [Project]) -> [Project] {
        projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> Project? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let project = Project(name: cleaned)
        hasLocalEdit = true
        projects = Self.sorted(projects + [project])
        saveNow()
        return project
    }

    func rename(_ id: UUID, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        update(id, debounced: false) { $0.name = cleaned }
        projects = Self.sorted(projects)
    }

    func setContext(_ context: SessionContext, for id: UUID) {
        update(id, debounced: true) { $0.context = context }
    }

    func setUsesPriorSessions(_ value: Bool, for id: UUID) {
        update(id, debounced: false) { $0.usesPriorSessions = value }
    }

    /// Removes the project record only. Moving or deleting its sessions is the caller's job.
    func delete(_ id: UUID) {
        hasLocalEdit = true
        projects.removeAll { $0.id == id }
        saveNow()
    }

    private func update(_ id: UUID, debounced: Bool, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var copy = projects[index]
        change(&copy)
        guard copy != projects[index] else { return }
        hasLocalEdit = true
        projects[index] = copy
        if debounced { scheduleSave() } else { saveNow() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        // Before the first load lands, memory holds only the new edits. Saving now would
        // overwrite the projects on disk. applyLoaded saves the merged list instead.
        guard isLoaded else { return }
        let snapshot = projects
        let storage = storage
        let previous = saveChain
        saveChain = Task {
            await previous?.value
            try? await storage.save(snapshot)
        }
    }

    /// Writes any pending debounced edit. Called on shutdown.
    func flush() async {
        await loadTask?.value
        if pendingSave != nil { saveNow() }
        await saveChain?.value
    }
}
