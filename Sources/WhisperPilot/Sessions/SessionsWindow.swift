import AppKit
import Combine
import SwiftUI

/// What the right-hand pane of the Sessions window shows.
enum SessionsSelection: Hashable {
    case home
    case project(UUID)
    case session(SessionID)
}

@MainActor
final class SessionsViewModel: ObservableObject {
    @Published var sessions: [SessionMeta] = []
    @Published var newSessionName: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selection: SessionsSelection = .home
    @Published var expandedProjects: Set<UUID> = []
    @Published var searchText: String = "" {
        didSet { scheduleContentSearch() }
    }
    /// Folder names of sessions whose transcript or summary matches the search text.
    @Published private(set) var contentMatches: Set<String> = []

    let projects: ProjectsStore
    private var searchTask: Task<Void, Never>?
    private var projectsObserver: AnyCancellable?

    init(projects: ProjectsStore) {
        self.projects = projects
        // The window reads project names through this model, so a project change
        // must redraw it too.
        projectsObserver = projects.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Set by the AppDelegate. Called when the user picks an action that should drop them
    /// into the live overlay.
    var onStartNew: ((SessionMeta) -> Void)?
    var onResume: ((SessionMeta) -> Void)?
    /// Called after a session's name or project changed, so a session that is open in the
    /// overlay keeps using the right project.
    var onSessionChanged: ((SessionMeta) -> Void)?
    /// Set by the AppDelegate. Invoked by the gear button in the Sessions header
    /// so users can jump straight into Settings without going through the menu
    /// bar — discoverability fix for first-time users who haven't found the
    /// menu bar icon yet.
    var onOpenSettings: (() -> Void)?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        sessions = await SessionStore.shared.listSessions()
    }

    // MARK: - Grouping and search

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The project a session sits in. Nil when it has none, or when the project no longer exists.
    func project(of session: SessionMeta) -> Project? {
        projects.project(id: session.projectID)
    }

    func sessions(in projectID: UUID) -> [SessionMeta] {
        sessions.filter { $0.projectID == projectID }
    }

    var ungroupedSessions: [SessionMeta] {
        sessions.filter { projects.project(id: $0.projectID) == nil }
    }

    /// Sessions matching the search, across every project. Matches the title, the project
    /// name, and (once the background read finishes) the transcript and summary.
    var searchResults: [SessionMeta] {
        sessions.filter { matchesSearch($0) }
    }

    func matchesSearch(_ session: SessionMeta) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if Self.contains(session.displayName, query) { return true }
        if let name = project(of: session)?.name, Self.contains(name, query) { return true }
        return contentMatches.contains(session.folderName)
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func scheduleContentSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            contentMatches = []
            return
        }
        // Wait for a pause in typing, then read files off the main thread.
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let hits = await SessionStore.shared.sessionsMatchingContent(query)
            guard !Task.isCancelled else { return }
            self?.contentMatches = hits
        }
    }

    // MARK: - Sessions

    func createNew(name: String? = nil, in projectID: UUID? = nil) async {
        do {
            let raw = name ?? newSessionName
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = try await SessionStore.shared.createSession(
                name: trimmed.isEmpty ? nil : trimmed,
                projectID: projectID
            )
            if name == nil { newSessionName = "" }
            onStartNew?(meta)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume(_ meta: SessionMeta) {
        onResume?(meta)
    }

    func delete(_ meta: SessionMeta) async {
        do {
            try await SessionStore.shared.deleteSession(meta.id)
            if selection == .session(meta.id) { selection = .home }
            await refresh()
        } catch {
            errorMessage = "Couldn’t move \(meta.displayName) to Trash: \(error.localizedDescription)"
        }
    }

    func rename(_ meta: SessionMeta, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meta.displayName else { return }
        do {
            if let updated = try await SessionStore.shared.renameSession(meta.id, to: trimmed) {
                onSessionChanged?(updated)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInFinder(_ meta: SessionMeta) async {
        let url = await SessionStore.shared.sessionFolder(for: meta.id)
        NSWorkspace.shared.open(url)
    }

    /// Moves a session into a project, or out of all projects when `projectID` is nil.
    func move(_ session: SessionMeta, to projectID: UUID?) async {
        guard session.projectID != projectID else { return }
        do {
            if let updated = try await SessionStore.shared.setProject(projectID, for: session.id) {
                onSessionChanged?(updated)
            }
            if let projectID { expandedProjects.insert(projectID) }
            await refresh()
        } catch {
            errorMessage = "Couldn’t move \(session.displayName): \(error.localizedDescription)"
        }
    }

    /// Used by drag and drop, which only knows the folder name.
    func moveSession(folderName: String, to projectID: UUID?) async {
        guard let session = sessions.first(where: { $0.folderName == folderName }) else { return }
        await move(session, to: projectID)
    }

    // MARK: - Projects

    func createProject(named name: String) {
        guard let project = projects.create(name: name) else { return }
        expandedProjects.insert(project.id)
        selection = .project(project.id)
    }

    func renameProject(_ id: UUID, to name: String) {
        projects.rename(id, to: name)
    }

    /// Deletes the project. Its sessions stay and move to ungrouped, unless `deleteSessions`
    /// is true (the caller has asked the user to confirm), in which case they go to the Trash.
    func deleteProject(_ id: UUID, deleteSessions: Bool) async {
        if deleteSessions {
            for member in sessions(in: id) {
                do {
                    try await SessionStore.shared.deleteSession(member.id)
                } catch {
                    errorMessage = "Couldn’t move \(member.displayName) to Trash: \(error.localizedDescription)"
                }
            }
        }
        // Whatever is left (all of them when keeping sessions) becomes ungrouped.
        await SessionStore.shared.clearProject(id)
        projects.delete(id)
        expandedProjects.remove(id)
        if selection == .project(id) { selection = .home }
        await refresh()
    }
}

@MainActor
final class SessionsWindowController: NSWindowController {
    init(viewModel: SessionsViewModel, globalContext: GlobalContextStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.brandLabel
        window.titlebarAppearsTransparent = true
        // Force a fully opaque, solid window background. The SwiftUI `.windowBackground`
        // shape style and the `titlebarAppearsTransparent + fullSizeContentView` combo
        // can otherwise allow the desktop / wallpaper underneath to bleed through,
        // which destroys text contrast over busy backgrounds. We pin both layers (the
        // AppKit window and the SwiftUI root) to a solid system color so the only
        // thing behind the text is a known, opaque surface.
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionsView(vm: viewModel, globalContext: globalContext))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

struct SessionsView: View {
    @ObservedObject var vm: SessionsViewModel
    @ObservedObject var globalContext: GlobalContextStore
    @State private var hoveredSessionID: SessionID?
    @State private var sessionPendingDeletion: SessionMeta?
    @State private var sessionPendingRename: SessionMeta?
    @State private var renameDraft: String = ""
    @State private var showingNewProject = false
    @State private var newProjectDraft: String = ""
    @State private var projectPendingRename: Project?
    @State private var projectRenameDraft: String = ""
    @State private var projectPendingDeletion: Project?
    @State private var projectPendingSessionDeletion: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                SessionsSidebar(vm: vm, actions: sidebarActions)
                    .frame(width: 270)
                Divider().opacity(0.4)
                detail
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        // Solid system colour rather than the `.windowBackground` material — the
        // material can pick up colour from anything behind the window (translucent
        // titlebar, accessibility "reduce transparency" off, etc.), which hurt text
        // contrast over colourful desktops.
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await vm.refresh() }
        .alert(
            "Delete session?",
            isPresented: deletePresentationBinding,
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await vm.delete(session) }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("This permanently removes the transcript, chat, and metadata folder for “\(session.displayName)” from disk. This action cannot be undone.")
        }
        .alert(
            "Rename session",
            isPresented: renamePresentationBinding,
            presenting: sessionPendingRename
        ) { session in
            TextField("Session name", text: $renameDraft)
            Button("Rename") {
                Task { await vm.rename(session, to: renameDraft) }
                sessionPendingRename = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingRename = nil
            }
        } message: { _ in
            Text("Only the display name changes — the transcript, chat, and files on disk stay where they are.")
        }
        .alert("New project", isPresented: $showingNewProject) {
            TextField("Project name", text: $newProjectDraft)
            Button("Create") { vm.createProject(named: newProjectDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A project groups related sessions, like a weekly meeting. You can add instructions and files for the AI inside it.")
        }
        .alert(
            "Rename project",
            isPresented: Binding(
                get: { projectPendingRename != nil },
                set: { if !$0 { projectPendingRename = nil } }
            ),
            presenting: projectPendingRename
        ) { project in
            TextField("Project name", text: $projectRenameDraft)
            Button("Rename") {
                vm.renameProject(project.id, to: projectRenameDraft)
                projectPendingRename = nil
            }
            Button("Cancel", role: .cancel) { projectPendingRename = nil }
        } message: { _ in
            Text("Only the project name changes. Its sessions stay in it.")
        }
        .alert(
            "Delete project?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            presenting: projectPendingDeletion
        ) { project in
            let count = vm.sessions(in: project.id).count
            Button("Delete project, keep sessions") {
                Task { await vm.deleteProject(project.id, deleteSessions: false) }
                projectPendingDeletion = nil
            }
            if count > 0 {
                Button("Also delete \(count) session\(count == 1 ? "" : "s")…", role: .destructive) {
                    projectPendingSessionDeletion = project
                    projectPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
        } message: { project in
            Text("“\(project.name)” and its instructions and files will be removed. Its sessions are not deleted — they move back to your ungrouped sessions.")
        }
        .alert(
            "Move sessions to Trash?",
            isPresented: Binding(
                get: { projectPendingSessionDeletion != nil },
                set: { if !$0 { projectPendingSessionDeletion = nil } }
            ),
            presenting: projectPendingSessionDeletion
        ) { project in
            let count = vm.sessions(in: project.id).count
            Button("Move \(count) session\(count == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await vm.deleteProject(project.id, deleteSessions: true) }
                projectPendingSessionDeletion = nil
            }
            Button("Cancel", role: .cancel) { projectPendingSessionDeletion = nil }
        } message: { project in
            Text("This deletes the project “\(project.name)” and moves all of its transcripts and chats to the Trash. You can restore them from there.")
        }
        .alert("Something went wrong", isPresented: errorPresentationBinding) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch vm.selection {
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.xl) {
                    globalContextSection
                    newSessionSection
                    historySection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, WP.Space.xl)
            }
        case .project(let id):
            if let project = vm.projects.project(id: id) {
                ProjectDetailView(vm: vm, projects: vm.projects, project: project, actions: sidebarActions, sessionActions: sessionRowActions)
            } else {
                EmptyProjectSelection()
            }
        case .session(let id):
            if let session = vm.sessions.first(where: { $0.id == id }) {
                SessionDetailView(vm: vm, session: session, actions: sessionRowActions)
            } else {
                EmptyProjectSelection()
            }
        }
    }

    private var sidebarActions: SessionsSidebarActions {
        SessionsSidebarActions(
            requestDeleteSession: { sessionPendingDeletion = $0 },
            requestRenameSession: { session in
                renameDraft = session.displayName
                sessionPendingRename = session
            },
            requestNewProject: {
                newProjectDraft = ""
                showingNewProject = true
            },
            requestRenameProject: { project in
                projectRenameDraft = project.name
                projectPendingRename = project
            },
            requestDeleteProject: { projectPendingDeletion = $0 }
        )
    }

    private var sessionRowActions: (delete: (SessionMeta) -> Void, rename: (SessionMeta) -> Void) {
        (
            delete: { sessionPendingDeletion = $0 },
            rename: { session in
                renameDraft = session.displayName
                sessionPendingRename = session
            }
        )
    }

    private var errorPresentationBinding: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { isPresented in
                if !isPresented { vm.errorMessage = nil }
            }
        )
    }

    private var renamePresentationBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingRename != nil },
            set: { isPresented in
                if !isPresented { sessionPendingRename = nil }
            }
        )
    }

    private var deletePresentationBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { sessionPendingDeletion = nil }
            }
        )
    }

    private var header: some View {
        HStack(spacing: WP.Space.md) {
            BrandLogo().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.brandLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("Sessions")
                    .font(.system(size: 18, weight: .semibold))
                Text("Each session keeps its own transcript and AI conversation on disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Renders only when a newer GitHub release exists. Sessions is the
            // window returning users see most, so the upgrade nudge lives here
            // too, not just in Settings.
            UpdateAvailableButton()
            // Expanded form: the Sessions window has plenty of horizontal
            // room in its header bar, and this is one of the surfaces a
            // returning user is most likely to be looking at — better
            // discoverability than the cramped overlay composer row.
            SupportLink(style: .expanded)
            Button {
                NSWorkspace.shared.open(SessionStore.shared.rootURL)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            // Settings shortcut. The menu bar icon also opens Settings, but
            // first-time users often miss the LSUIElement icon entirely — this
            // gives the Sessions window a direct entry point that matches the
            // gear-icon convention every other macOS app uses.
            Button {
                vm.onOpenSettings?()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Open Settings (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, WP.Space.md + 2)
        // `.bar` is a translucent material that pulls colour from whatever's behind
        // the window. Use a solid, slightly-different system colour so the header
        // still reads as a distinct band from the scroll area without leaking the
        // desktop colour through.
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// App-wide context that gets injected into every session's AI prompt. Same
    /// component as the per-session dropdown — only the binding target differs —
    /// with a warning surfaced *inside* the expanded panel where users are about
    /// to type, since this is where they'll make the cost mistake.
    private var globalContextSection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            SectionHeader(
                title: "Global context",
                subtitle: "Applied to every session. Use sparingly — see the warning inside."
            )
            ContextDropdown(
                context: $globalContext.context,
                title: "Global context",
                notice: AnyView(
                    HStack(alignment: .top, spacing: WP.Space.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("This text and these files are sent with **every** AI prompt across **every** session. Be conservative — more context means higher token cost per call and slower responses. Only add things every conversation truly needs (e.g. your name, role, common terminology). Use per-session context inside a session for anything specific to that conversation.")
                            .font(WP.TextStyle.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(WP.Space.xs)
                    .background(
                        RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                    )
                )
            )
        }
    }

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            SectionHeader(title: "Start a new session", subtitle: "Recommended for most calls — uses the fewest tokens.")
            HStack(spacing: WP.Space.sm) {
                TextField("Optional name (e.g. \"Q3 review with Acme\")", text: $vm.newSessionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.createNew() } }
                Button {
                    Task { await vm.createNew() }
                } label: {
                    Label("Start new", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var visibleHistory: [SessionMeta] {
        vm.isSearching ? vm.searchResults : vm.sessions
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Past sessions", subtitle: nil)
                Spacer()
                if !vm.sessions.isEmpty {
                    Text("\(visibleHistory.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(.quinary)
                        )
                }
            }

            ResumeHint()

            if vm.sessions.isEmpty {
                EmptyHistoryState()
            } else if visibleHistory.isEmpty {
                Text("No sessions match “\(vm.searchText)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: WP.Space.sm) {
                    ForEach(visibleHistory) { session in
                        SessionRow(
                            session: session,
                            isHovered: hoveredSessionID == session.id,
                            vm: vm,
                            onRequestDelete: { sessionPendingDeletion = session },
                            onRequestRename: {
                                renameDraft = session.displayName
                                sessionPendingRename = session
                            }
                        )
                        .onHover { hovering in
                            hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
                        }
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ResumeHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: WP.Space.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 13))
            Text("Resuming a session re-includes its prior transcript and chat in every AI prompt. Prefer a fresh session unless you actually need the prior context — it'll cost fewer tokens.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(WP.Space.md - 2)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(Color.blue.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct EmptyHistoryState: View {
    var body: some View {
        VStack(spacing: WP.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No saved sessions yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start one above — your transcripts and chats will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(.quinary)
        )
    }
}

struct SessionRow: View {
    let session: SessionMeta
    let isHovered: Bool
    let vm: SessionsViewModel
    let onRequestDelete: () -> Void
    let onRequestRename: () -> Void

    var body: some View {
        HStack(spacing: WP.Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let project = vm.project(of: session) {
                Label(project.name, systemImage: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .chip(.neutral)
                    .help("Project: \(project.name)")
            }

            if let modelBadge = modelBadgeContent {
                Text(modelBadge.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(modelBadge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(modelBadge.color.opacity(0.12))
                    )
                    .overlay(
                        Capsule().strokeBorder(modelBadge.color.opacity(0.4), lineWidth: 0.5)
                    )
                    .help(modelBadge.tooltip)
            }

            Button {
                vm.resume(session)
            } label: {
                Text("Resume")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Menu {
                Button(action: onRequestRename) {
                    Label("Rename…", systemImage: "pencil")
                }
                MoveToProjectMenu(session: session, projects: vm.projects) { target in
                    Task { await vm.move(session, to: target) }
                }
                Button {
                    Task { await vm.openInFinder(session) }
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive, action: onRequestDelete) {
                    Label("Delete session", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, WP.Space.md)
        .padding(.vertical, WP.Space.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quinary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .strokeBorder(.separator.opacity(isHovered ? 0.5 : 0.25), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Vendor-colored badge content for the model this session uses. Nil when
    /// the session was created before the per-session-model feature shipped
    /// and hasn't been opened since — those rows just don't show a badge
    /// rather than render a misleading "default" pill that lies about what
    /// the session will actually use on resume (resume reads the *current*
    /// global default at that moment, which may differ from launch-time).
    private var modelBadgeContent: (label: String, color: Color, tooltip: String)? {
        guard let id = session.selectedModel,
              let model = AIModelRegistry.model(for: id) else { return nil }
        return (
            label: model.displayName,
            color: model.vendor.accentColor,
            tooltip: "This session uses \(model.displayName). Resume to continue with the same model."
        )
    }

    private var detailLine: String {
        let relative = SessionRow.relativeFormatter.localizedString(for: session.lastUsedAt, relativeTo: Date())
        return "\(relative) · \(session.transcriptLineCount) transcript line\(session.transcriptLineCount == 1 ? "" : "s") · \(session.chatTurnCount) chat turn\(session.chatTurnCount == 1 ? "" : "s")"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
