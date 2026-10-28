import SwiftUI

/// The page for one project: start a session in it, edit its instructions and files, and
/// browse its sessions.
struct ProjectDetailView: View {
    @ObservedObject var vm: SessionsViewModel
    @ObservedObject var projects: ProjectsStore
    let project: Project
    let actions: SessionsSidebarActions
    let sessionActions: (delete: (SessionMeta) -> Void, rename: (SessionMeta) -> Void)

    @State private var newSessionName: String = ""
    @State private var hoveredSessionID: SessionID?

    private var sessions: [SessionMeta] {
        let all = vm.sessions(in: project.id)
        return vm.isSearching ? all.filter { vm.matchesSearch($0) } : all
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.xl) {
                titleBar
                newSessionSection
                instructionsSection
                sessionsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, WP.Space.xl)
        }
    }

    private var titleBar: some View {
        HStack(spacing: WP.Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                let count = vm.sessions(in: project.id).count
                Text("\(count) session\(count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                actions.requestRenameProject(project)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                actions.requestDeleteProject(project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            SectionHeader(
                title: "Start a session in this project",
                subtitle: "It opens already filed here, with the project's instructions and files."
            )
            HStack(spacing: WP.Space.sm) {
                TextField("Optional name (the AI names it when you finish)", text: $newSessionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(start)
                Button(action: start) {
                    Label("Start new", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private func start() {
        let name = newSessionName
        newSessionName = ""
        Task { await vm.createNew(name: name, in: project.id) }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            SectionHeader(
                title: "Instructions and files",
                subtitle: "Sent with every AI prompt in this project's sessions."
            )
            ContextDropdown(
                context: Binding(
                    get: { projects.project(id: project.id)?.context ?? SessionContext() },
                    set: { projects.setContext($0, for: project.id) }
                ),
                title: "Project instructions",
                notesLabel: "Instructions",
                startExpanded: true
            )
            Toggle(isOn: Binding(
                get: { project.usesPriorSessions },
                set: { projects.setUsesPriorSessions($0, for: project.id) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use earlier sessions as context")
                        .font(.system(size: 12, weight: .medium))
                    Text("Adds short summaries of this project's earlier sessions, newest first, so the AI can pick up where you left off. Costs a few extra tokens per prompt.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            SectionHeader(title: "Sessions", subtitle: nil)
            if sessions.isEmpty {
                Text(vm.isSearching ? "No sessions in this project match the search." : "No sessions yet. Start one above, or drag sessions here from the sidebar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: WP.Space.sm) {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            isHovered: hoveredSessionID == session.id,
                            vm: vm,
                            onRequestDelete: { sessionActions.delete(session) },
                            onRequestRename: { sessionActions.rename(session) }
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

/// Page for a session picked in the sidebar: its row (with Resume) and its recap.
struct SessionDetailView: View {
    @ObservedObject var vm: SessionsViewModel
    let session: SessionMeta
    let actions: (delete: (SessionMeta) -> Void, rename: (SessionMeta) -> Void)

    @State private var summary: SessionSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.lg) {
                SessionRow(
                    session: session,
                    isHovered: false,
                    vm: vm,
                    onRequestDelete: { actions.delete(session) },
                    onRequestRename: { actions.rename(session) }
                )
                VStack(alignment: .leading, spacing: WP.Space.sm) {
                    SectionHeader(title: "Recap", subtitle: nil)
                    if let summary {
                        Text(summary.summary)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No recap yet. One is written when you stop a session that has enough conversation.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, WP.Space.xl)
        }
        .task(id: session.id) {
            summary = await SessionStore.shared.loadSummary(session.id)
        }
    }
}

struct EmptyProjectSelection: View {
    var body: some View {
        VStack(spacing: WP.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
