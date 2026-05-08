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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Pilot — Sessions"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionsView(vm: viewModel))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

struct SessionsView: View {
    @ObservedObject var vm: SessionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            newSessionSection
            Divider()
            historySection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .task { await vm.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandLogo().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Pilot Sessions")
                    .font(.title2.weight(.semibold))
                Text("Each session keeps its own meeting transcript and AI conversation on disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.open(SessionStore.shared.rootURL)
            }
            .buttonStyle(.bordered)
        }
    }

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start a new session")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("Optional name (e.g. \"Q3 review with Acme\")", text: $vm.newSessionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.createNew() } }
                Button("Start new") {
                    Task { await vm.createNew() }
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("A new session starts with an empty transcript and chat. Recommended for most calls — uses the fewest tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Past sessions")
                .font(.headline)

            resumeWarning

            if vm.sessions.isEmpty {
                Text("No saved sessions yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.sessions) { session in
                            SessionRow(session: session, vm: vm)
                        }
                    }
                }
            }
        }
    }

    private var resumeWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.callout)
            Text("Resuming a session re-includes its prior transcript and chat in every AI prompt. Prefer a fresh session unless you actually need the prior context — it'll cost fewer tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.07)))
    }
}

private struct SessionRow: View {
    let session: SessionMeta
    let vm: SessionsViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.body.weight(.medium))
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Resume") {
                vm.resume(session)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Menu {
                Button("Open in Finder") {
                    Task { await vm.openInFinder(session) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await vm.delete(session) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var detailLine: String {
        let relative = SessionRow.relativeFormatter.localizedString(for: session.lastUsedAt, relativeTo: Date())
        return "\(relative) · \(session.transcriptLineCount) transcript line\(session.transcriptLineCount == 1 ? "" : "s") · \(session.chatTurnCount) chat turn\(session.chatTurnCount == 1 ? "" : "s") · \(session.folderName)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
