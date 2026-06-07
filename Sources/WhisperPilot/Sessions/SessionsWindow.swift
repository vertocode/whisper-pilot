import AppKit
import Combine
import SwiftUI

@MainActor
final class SessionsViewModel: ObservableObject {
    @Published var sessions: [SessionMeta] = []
    @Published var newSessionName: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Set by the AppDelegate. Called when the user picks an action that should drop them
    /// into the live overlay.
    var onStartNew: ((SessionMeta) -> Void)?
    var onResume: ((SessionMeta) -> Void)?
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

    func createNew() async {
        do {
            let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = try await SessionStore.shared.createSession(name: trimmed.isEmpty ? nil : trimmed)
            newSessionName = ""
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
        try? await SessionStore.shared.deleteSession(meta.id)
        await refresh()
    }

    func rename(_ meta: SessionMeta, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meta.displayName else { return }
        do {
            _ = try await SessionStore.shared.renameSession(meta.id, to: trimmed)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInFinder(_ meta: SessionMeta) async {
        let url = await SessionStore.shared.sessionFolder(for: meta.id)
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SessionsWindowController: NSWindowController {
    init(viewModel: SessionsViewModel, globalContext: GlobalContextStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.xl) {
                    globalContextSection
                    newSessionSection
                    historySection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, WP.Space.xl)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: WP.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Past sessions", subtitle: nil)
                Spacer()
                if !vm.sessions.isEmpty {
                    Text("\(vm.sessions.count)")
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
            } else {
                LazyVStack(spacing: WP.Space.sm) {
                    ForEach(vm.sessions) { session in
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

private struct SectionHeader: View {
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

private struct SessionRow: View {
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
