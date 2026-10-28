import SwiftUI
import UniformTypeIdentifiers

/// Actions the sidebar and project page ask the window to run. The window owns the alerts.
struct SessionsSidebarActions {
    var requestDeleteSession: (SessionMeta) -> Void
    var requestRenameSession: (SessionMeta) -> Void
    var requestNewProject: () -> Void
    var requestRenameProject: (Project) -> Void
    var requestDeleteProject: (Project) -> Void
}

/// "Move to project" submenu, shared by the session row menu and the sidebar context menu.
struct MoveToProjectMenu: View {
    let session: SessionMeta
    @ObservedObject var projects: ProjectsStore
    let onMove: (UUID?) -> Void

    var body: some View {
        Menu {
            ForEach(projects.projects) { project in
                Button {
                    onMove(project.id)
                } label: {
                    Label(project.name, systemImage: session.projectID == project.id ? "checkmark" : "folder")
                }
            }
            if !projects.projects.isEmpty { Divider() }
            Button {
                onMove(nil)
            } label: {
                Label("No project", systemImage: session.projectID == nil ? "checkmark" : "tray")
            }
        } label: {
            Label("Move to project", systemImage: "folder.badge.plus")
        }
    }
}

/// What a dragged session is carried as. The prefix keeps unrelated dragged text from
/// being mistaken for a session.
enum SessionDragPayload {
    static let prefix = "whisperpilot-session:"

    static func provider(for session: SessionMeta) -> NSItemProvider {
        NSItemProvider(object: (prefix + session.folderName) as NSString)
    }

    static func folderName(from text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let name = String(text.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }
}

struct SessionsSidebar: View {
    @ObservedObject var vm: SessionsViewModel
    @ObservedObject private var projects: ProjectsStore
    let actions: SessionsSidebarActions

    private enum DropTarget: Equatable {
        case project(UUID)
        case ungrouped
    }
    @State private var dropTarget: DropTarget?

    init(vm: SessionsViewModel, actions: SessionsSidebarActions) {
        self.vm = vm
        self._projects = ObservedObject(wrappedValue: vm.projects)
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, WP.Space.md)
                .padding(.vertical, WP.Space.md)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.xs) {
                    if vm.isSearching {
                        searchResultsList
                    } else {
                        homeRow
                        projectsHeader
                        ForEach(projects.projects) { project in
                            projectGroup(project)
                        }
                        ungroupedGroup
                    }
                }
                .padding(.horizontal, WP.Space.sm)
                .padding(.bottom, WP.Space.md)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: WP.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search sessions", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if vm.isSearching {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, WP.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var searchResultsList: some View {
        let results = vm.searchResults
        sectionLabel("Results (\(results.count))")
        if results.isEmpty {
            Text("No sessions match.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, WP.Space.sm)
        }
        ForEach(results) { session in
            SidebarSessionRow(vm: vm, session: session, actions: actions, showsProject: true)
        }
    }

    // MARK: - Home, projects, ungrouped

    private var homeRow: some View {
        Button {
            vm.selection = .home
        } label: {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("All sessions")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                countBadge(vm.sessions.count)
            }
            .padding(.horizontal, WP.Space.sm)
            .padding(.vertical, 6)
            .background(rowBackground(selected: vm.selection == .home))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var projectsHeader: some View {
        HStack {
            sectionLabel("Projects")
            Spacer()
            Button(action: actions.requestNewProject) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New project")
        }
        .padding(.trailing, WP.Space.sm)
        .padding(.top, WP.Space.sm)
    }

    private func projectGroup(_ project: Project) -> some View {
        let members = vm.sessions(in: project.id)
        let isExpanded = vm.expandedProjects.contains(project.id)
        let target = DropTarget.project(project.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: WP.Space.xs) {
                Button {
                    toggle(project.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")

                Button {
                    vm.selection = .project(project.id)
                    vm.expandedProjects.insert(project.id)
                } label: {
                    HStack(spacing: WP.Space.sm) {
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Text(project.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        countBadge(members.count)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, WP.Space.xs)
            .padding(.vertical, 5)
            .background(rowBackground(selected: vm.selection == .project(project.id)))
            .contextMenu {
                Button {
                    Task { await vm.createNew(name: "", in: project.id) }
                } label: {
                    Label("New session in project", systemImage: "plus.circle")
                }
                Button {
                    actions.requestRenameProject(project)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    actions.requestDeleteProject(project)
                } label: {
                    Label("Delete project…", systemImage: "trash")
                }
            }

            if isExpanded {
                if members.isEmpty {
                    Text("Drop sessions here")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 34)
                        .padding(.vertical, 3)
                }
                ForEach(members) { session in
                    SidebarSessionRow(vm: vm, session: session, actions: actions, showsProject: false)
                        .padding(.leading, WP.Space.lg)
                }
            }
        }
        .overlay(dropOutline(active: dropTarget == target))
        .onDrop(of: [.plainText], isTargeted: targetBinding(target)) { providers in
            handleDrop(providers, to: project.id)
        }
    }

    private var ungroupedGroup: some View {
        let target = DropTarget.ungrouped
        return VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Sessions")
                .padding(.top, WP.Space.sm)
            ForEach(vm.ungroupedSessions) { session in
                SidebarSessionRow(vm: vm, session: session, actions: actions, showsProject: false)
            }
            if vm.ungroupedSessions.isEmpty {
                Text(vm.sessions.isEmpty ? "No sessions yet" : "Drop sessions here to take them out of a project")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, WP.Space.sm)
            }
            // Keeps a drop area below the last row so there is always room to drop into.
            Color.clear.frame(height: 40)
        }
        .overlay(dropOutline(active: dropTarget == target))
        .onDrop(of: [.plainText], isTargeted: targetBinding(target)) { providers in
            handleDrop(providers, to: nil)
        }
    }

    // MARK: - Helpers

    private func toggle(_ id: UUID) {
        if vm.expandedProjects.contains(id) {
            vm.expandedProjects.remove(id)
        } else {
            vm.expandedProjects.insert(id)
        }
    }

    private func targetBinding(_ target: DropTarget) -> Binding<Bool> {
        Binding(
            get: { dropTarget == target },
            set: { targeted in
                if targeted {
                    dropTarget = target
                } else if dropTarget == target {
                    dropTarget = nil
                }
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider], to projectID: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString,
                  let folderName = SessionDragPayload.folderName(from: text as String) else { return }
            Task { @MainActor in
                await vm.moveSession(folderName: folderName, to: projectID)
            }
        }
        return true
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, WP.Space.sm)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func dropOutline(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: active ? 1.5 : 0)
            .allowsHitTesting(false)
    }
}

/// One session in the sidebar. Click selects it; drag moves it; right-click has the actions.
struct SidebarSessionRow: View {
    @ObservedObject var vm: SessionsViewModel
    let session: SessionMeta
    let actions: SessionsSidebarActions
    let showsProject: Bool

    private var isSelected: Bool { vm.selection == .session(session.id) }

    var body: some View {
        Button {
            vm.selection = .session(session.id)
        } label: {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WP.Space.sm)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { SessionDragPayload.provider(for: session) }
        .contextMenu {
            Button {
                vm.resume(session)
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button {
                actions.requestRenameSession(session)
            } label: {
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
            Button(role: .destructive) {
                actions.requestDeleteSession(session)
            } label: {
                Label("Delete session", systemImage: "trash")
            }
        }
    }

    private var caption: String {
        let relative = Self.relativeFormatter.localizedString(for: session.lastUsedAt, relativeTo: Date())
        if showsProject, let project = vm.project(of: session) {
            return "\(project.name) · \(relative)"
        }
        return relative
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
