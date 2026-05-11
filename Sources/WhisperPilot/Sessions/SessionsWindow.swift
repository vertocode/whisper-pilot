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

    func openInFinder(_ meta: SessionMeta) async {
        let url = await SessionStore.shared.sessionFolder(for: meta.id)
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SessionsWindowController: NSWindowController {
    init(viewModel: SessionsViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Pilot"
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionsView(vm: viewModel))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

struct SessionsView: View {
    @ObservedObject var vm: SessionsViewModel
    @State private var hoveredSessionID: SessionID?
    @State private var sessionPendingDeletion: SessionMeta?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.xl) {
                    newSessionSection
                    historySection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, WP.Space.xl)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(.windowBackground)
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
                Text("Sessions")
                    .font(.system(size: 18, weight: .semibold))
                Text("Each session keeps its own transcript and AI conversation on disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(SessionStore.shared.rootURL)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, WP.Space.md + 2)
        .background(.bar)
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
                            onRequestDelete: { sessionPendingDeletion = session }
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

            Button {
                vm.resume(session)
            } label: {
                Text("Resume")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Menu {
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
