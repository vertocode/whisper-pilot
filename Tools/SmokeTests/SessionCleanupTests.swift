import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func meta(_ name: String, lastUsed: Date, created: Date? = nil, project: UUID? = nil) -> SessionMeta {
        SessionMeta(folderName: name, displayName: name, createdAt: created ?? lastUsed, lastUsedAt: lastUsed, projectID: project)
    }

    private static func names(_ sessions: [SessionMeta]) -> [String] {
        sessions.map(\.folderName)
    }

    private static func exists(_ store: SessionStore, _ session: SessionMeta) async -> Bool {
        let folder = await store.sessionFolder(for: session.id)
        return FileManager.default.fileExists(atPath: folder.path)
    }

    /// Rewrites a real session's metadata so it looks last used on `lastUsed`.
    private static func backdate(_ session: SessionMeta, to lastUsed: Date, in store: SessionStore) async throws {
        var old = session
        old.createdAt = lastUsed
        old.lastUsedAt = lastUsed
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = await store.sessionFolder(for: session.id).appendingPathComponent("metadata.json")
        try encoder.encode(old).write(to: url, options: .atomic)
    }

    private static func makeFixture() async -> (root: URL, store: SessionStore, projects: ProjectsStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let store = SessionStore(baseURL: sessionsDir)
        let projects = await ProjectsStore(storage: ProjectStorage(directory: root, sessionsDirectory: sessionsDir))
        return (root, store, projects)
    }

    static func runSessionCleanupSuite() async {
        await suite("SessionCleanup: age cutoffs") {
            let now = date("2026-03-31T12:00:00Z")
            await expect(SessionAgeLimit.oneMonth.cutoff(from: now, calendar: utc) == date("2026-02-28T12:00:00Z"),
                         "one month back from a 31st lands on the last day of February")
            await expect(SessionAgeLimit.threeMonths.cutoff(from: now, calendar: utc) == date("2025-12-31T12:00:00Z"), "three months")
            await expect(SessionAgeLimit.sixMonths.cutoff(from: now, calendar: utc) == date("2025-09-30T12:00:00Z"), "six months")
            await expect(SessionAgeLimit.oneYear.cutoff(from: now, calendar: utc) == date("2025-03-31T12:00:00Z"), "one year")
        }

        await suite("SessionCleanup: matching by age") {
            let now = date("2026-03-31T12:00:00Z")
            let cutoff = SessionAgeLimit.oneMonth.cutoff(from: now, calendar: utc)
            let project = UUID()
            let sessions = [
                meta("just-before", lastUsed: cutoff.addingTimeInterval(-1)),
                meta("exactly-at", lastUsed: cutoff),
                meta("just-after", lastUsed: cutoff.addingTimeInterval(1)),
                meta("in-project", lastUsed: date("2025-01-01T00:00:00Z"), project: project),
                meta("old-but-reused", lastUsed: now, created: date("2020-01-01T00:00:00Z")),
                meta("unknown-age", lastUsed: .distantPast),
            ]
            let match = SessionCleanup.match(.oneMonth, in: sessions, openSession: nil, now: now, calendar: utc)
            await expect(names(match.sessions) == ["just-before", "in-project"],
                         "only sessions last used before the cutoff match, inside projects too: \(names(match.sessions))")
            await expect(match.keptOpenSession == nil, "nothing is reported kept without an open session")

            let year = SessionCleanup.match(.oneYear, in: sessions, openSession: nil, now: now, calendar: utc)
            await expect(names(year.sessions) == ["in-project"], "a longer limit matches fewer sessions")

            let openOld = SessionCleanup.match(.oneMonth, in: sessions, openSession: sessions[3].id, now: now, calendar: utc)
            await expect(names(openOld.sessions) == ["just-before"], "the open session never matches")
            await expect(openOld.keptOpenSession?.folderName == "in-project", "the open session is reported as kept")

            let openRecent = SessionCleanup.match(.oneMonth, in: sessions, openSession: sessions[2].id, now: now, calendar: utc)
            await expect(openRecent.keptOpenSession == nil, "an open session too new to match is not mentioned")

            let none = SessionCleanup.match(.oneYear, in: [meta("new", lastUsed: now)], openSession: nil, now: now, calendar: utc)
            await expect(none.sessions.isEmpty, "zero matches when everything is recent")
        }

        await suite("SessionCleanup: bulk delete removes files and keeps the open session") {
            let (root, store, _) = await makeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let first = try await store.createSession(name: "First")
                let second = try await store.createSession(name: "Second", projectID: UUID())
                let open = try await store.createSession(name: "Open")
                let untouched = try await store.createSession(name: "Untouched")
                await store.saveSummary(SessionSummary(summary: "Recap", transcriptBytes: 1, generatedAt: Date()), for: second.id)
                await store.saveContext(SessionContext(), to: second.id)
                await store.appendTranscriptLine(channel: .system, text: "still here", at: Date(), to: open.id)

                let outcome = await SessionCleanup.delete([first, open, second], from: store) { open.id }

                await expect(Set(outcome.deleted) == [first.id, second.id], "the two closed sessions are deleted")
                await expect(names(outcome.skippedOpen) == [open.folderName], "the open session is reported as skipped")
                await expect(outcome.failed.isEmpty, "nothing failed")
                let firstGone = await exists(store, first)
                let secondGone = await exists(store, second)
                await expect(!firstGone && !secondGone, "whole folders are gone, recap and context included")
                let transcript = await store.loadTranscriptMarkdown(open.id)
                await expect(transcript.contains("still here"), "the open session keeps its transcript")
                let listed = Set(await store.listSessions().map(\.folderName))
                await expect(listed == [open.folderName, untouched.folderName], "the list reflects the deletion: \(listed)")
            } catch {
                await expect(false, "bulk delete fixture threw: \(error)")
            }
        }

        await suite("SessionCleanup: a session opened mid-run, and a failure mid-run") {
            let (root, store, _) = await makeFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let first = try await store.createSession(name: "First")
                let second = try await store.createSession(name: "Second")
                var calls = 0
                let opened = await SessionCleanup.delete([first, second], from: store) {
                    calls += 1
                    return calls == 1 ? nil : second.id
                }
                await expect(opened.deleted == [first.id], "the session before it is deleted")
                await expect(names(opened.skippedOpen) == [second.folderName], "a session opened during the run survives")
                let secondStillThere = await exists(store, second)
                await expect(secondStillThere, "its folder is still there")

                let missing = meta("no-such-folder", lastUsed: Date())
                let failed = await SessionCleanup.delete([missing, second], from: store) { nil }
                await expect(names(failed.failed.map(\.session)) == ["no-such-folder"], "the failure is reported")
                await expect(failed.deleted == [second.id], "one failure does not stop the batch")
            } catch {
                await expect(false, "mid-run fixture threw: \(error)")
            }
        }

        await suite("Sessions window: picking sessions") {
            await runSelectionChecks()
        }

        await suite("Sessions window: deleting picked and old sessions") {
            await runDeletionChecks()
        }
    }

    @MainActor
    private static func runSelectionChecks() async {
        let (root, store, projects) = await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            guard let project = projects.create(name: "Weekly") else {
                await expect(false, "project was created")
                return
            }
            let loose = try await store.createSession(name: "Loose")
            let filed = try await store.createSession(name: "Filed", projectID: project.id)
            let open = try await store.createSession(name: "Open")
            let vm = SessionsViewModel(projects: projects, store: store)
            vm.openSessionID = { open.id }
            await vm.refresh()

            await expect(vm.checkState(for: loose) == nil, "rows have no checkbox outside selection mode")
            vm.beginSelectingSessions()
            await expect(vm.checkState(for: loose) == .unchecked, "rows start unchecked")
            await expect(vm.checkState(for: open) == .open, "the open session is marked")

            vm.toggleChecked(open)
            await expect(vm.checkedSessionIDs.isEmpty, "the open session can't be ticked")

            vm.toggleChecked(loose)
            await expect(vm.checkState(for: loose) == .checked, "ticking checks a row")
            vm.toggleChecked(loose)
            await expect(vm.checkState(for: loose) == .unchecked, "ticking again unchecks it")

            vm.checkAllSelectable()
            await expect(vm.checkedSessionIDs == [loose.id, filed.id], "select all takes everything but the open session")
            vm.clearChecked()
            await expect(vm.checkedSessionIDs.isEmpty, "clear unchecks everything")

            vm.selection = .project(project.id)
            vm.checkAllSelectable()
            await expect(vm.checkedSessionIDs == [filed.id], "on a project page, select all stays inside the project")

            vm.selection = .home
            vm.toggleChecked(loose)
            try await store.deleteSession(loose.id)
            await vm.refresh()
            await expect(vm.checkedSessionIDs == [filed.id], "a session that disappeared drops out of the selection")

            vm.endSelectingSessions()
            await expect(!vm.isSelectingSessions && vm.checkedSessionIDs.isEmpty, "done leaves selection mode clean")
        } catch {
            await expect(false, "selection fixture threw: \(error)")
        }
    }

    @MainActor
    private static func runDeletionChecks() async {
        let (root, store, projects) = await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            guard let project = projects.create(name: "Weekly") else {
                await expect(false, "project was created")
                return
            }
            let longAgo = date("2024-01-01T00:00:00Z")
            let picked = try await store.createSession(name: "Picked")
            let old = try await store.createSession(name: "Old")
            let oldFiled = try await store.createSession(name: "Old filed", projectID: project.id)
            let oldOpen = try await store.createSession(name: "Old open")
            let recent = try await store.createSession(name: "Recent")
            for session in [old, oldFiled, oldOpen] {
                try await backdate(session, to: longAgo, in: store)
            }
            var openID: SessionID? = oldOpen.id
            let vm = SessionsViewModel(projects: projects, store: store)
            vm.openSessionID = { openID }
            await vm.refresh()

            let match = vm.oldSessions(.oneYear, now: Date())
            await expect(Set(names(match.sessions)) == [old.folderName, oldFiled.folderName], "old sessions match from the stored dates")
            await expect(match.keptOpenSession?.folderName == oldOpen.folderName, "the old open session is called out")

            vm.beginSelectingSessions()
            vm.toggleChecked(picked)
            vm.selection = .session(picked.id)
            await vm.deleteSessions(vm.checkedSessions)
            await expect(!vm.isSelectingSessions && vm.checkedSessionIDs.isEmpty, "a clean delete leaves selection mode")
            await expect(vm.selection == .home, "the page of a deleted session closes")
            await expect(vm.deletionNotice == nil && vm.errorMessage == nil, "nothing to report after a clean delete")

            await vm.deleteSessions(match.sessions)
            await expect(Set(names(vm.sessions)) == [oldOpen.folderName, recent.folderName], "the list reloads without the old sessions")
            await expect(projects.project(id: project.id) != nil, "the project itself stays")

            // Picked while closed, then opened before Delete ran.
            openID = nil
            vm.beginSelectingSessions()
            vm.toggleChecked(oldOpen)
            let targets = vm.checkedSessions
            openID = oldOpen.id
            await vm.deleteSessions(targets)
            let openStillThere = await exists(store, oldOpen)
            await expect(openStillThere, "a session opened after picking survives")
            await expect(vm.deletionNotice?.contains("Old open") == true, "the user is told it was kept")

            let ghost = meta("no-such-folder", lastUsed: longAgo)
            vm.beginSelectingSessions()
            await vm.deleteSessions([ghost])
            await expect(vm.errorMessage?.contains("1 session") == true, "a failed delete is reported")
            await expect(vm.isSelectingSessions, "a failed delete stays in selection mode for a retry")
            await expect(!vm.isDeletingSessions, "the busy state clears")
        } catch {
            await expect(false, "deletion fixture threw: \(error)")
        }
    }
}
