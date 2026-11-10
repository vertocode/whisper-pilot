import SwiftUI

/// Asks how old a session must be, shows how many match, and deletes them.
struct DeleteOldSessionsSheet: View {
    @ObservedObject var vm: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var limit: SessionAgeLimit = .oneYear
    /// Fixed when the sheet opens, so the counts don't drift while it stays up.
    @State private var now = Date()
    /// Delete waits for the reload, so it never acts on a list from before the sheet opened.
    @State private var isReady = false

    var body: some View {
        let match = vm.oldSessions(limit, now: now)
        return VStack(alignment: .leading, spacing: WP.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete old sessions")
                    .font(.system(size: 15, weight: .semibold))
                Text("Age counts from each session’s last activity, like a new transcript line or chat message. Opening a session just to read it usually doesn’t count.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Age", selection: $limit) {
                ForEach(SessionAgeLimit.allCases) { option in
                    Text("\(option.title) (\(vm.oldSessions(option, now: now).sessions.count))")
                        .tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            summary(match)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    let targets = match.sessions
                    dismiss()
                    Task { await vm.deleteSessions(targets) }
                } label: {
                    Text("Delete \(SessionCleanup.countLabel(match.sessions.count))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isReady || match.sessions.isEmpty)
            }
        }
        .padding(WP.Space.xl)
        .frame(width: 400)
        // Picks up activity from a session that was running while this window stayed open.
        .task {
            await vm.refresh()
            isReady = true
        }
    }

    private func summary(_ current: SessionCleanup.AgeMatch) -> some View {
        VStack(alignment: .leading, spacing: WP.Space.xs) {
            Text(current.sessions.isEmpty
                 ? (current.keptOpenSession == nil ? "No sessions are this old." : "No other sessions are this old.")
                 : "\(SessionCleanup.countLabel(current.sessions.count)) will move to the Trash with their transcripts, chats, and recaps. Sessions inside projects are included.")
            if let kept = current.keptOpenSession {
                Text("“\(kept.displayName)” is this old too, but it’s open right now, so it will be kept.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
