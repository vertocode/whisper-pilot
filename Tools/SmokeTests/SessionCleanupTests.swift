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

    /// Keeps fake test sessions out of the real Trash.
    static let removeWithoutTrash: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    /// Waits out the pause the search box leaves after typing.
    @MainActor
    private static func search(_ text: String, in vm: SessionsViewModel) async {
        vm.searchText = text
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private static func makeFixture() async -> (root: URL, store: SessionStore, projects: ProjectsStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let store = SessionStore(baseURL: sessionsDir, removeItem: removeWithoutTrash)
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
            let match = SessionCleanup.match(.oneMonth, in: sessions, openSessions: [], now: now, calendar: utc)
            await expect(names(match.sessions) == ["just-before", "in-project"],
                         "only sessions last used before the cutoff match, inside projects too: \(names(match.sessions))")
            await expect(match.keptOpenSession == nil, "nothing is reported kept without an open session")

            let year = SessionCleanup.match(.oneYear, in: sessions, openSessions: [], now: now, calendar: utc)
            await expect(names(year.sessions) == ["in-project"], "a longer limit matches fewer sessions")

            let openOld = SessionCleanup.match(.oneMonth, in: sessions, openSessions: [sessions[3].id], now: now, calendar: utc)
            await expect(names(openOld.sessions) == ["just-before"], "the open session never matches")
            await expect(openOld.keptOpenSession?.folderName == "in-project", "the open session is reported as kept")

            let openRecent = SessionCleanup.match(.oneMonth, in: sessions, openSessions: [sessions[2].id], now: now, calendar: utc)
            await expect(openRecent.keptOpenSession == nil, "an open session too new to match is not mentioned")

            let none = SessionCleanup.match(.oneYear, in: [meta("new", lastUsed: now)], openSessions: [], now: now, calendar: utc)
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

                let outcome = await SessionCleanup.delete([first, open, second], from: store) { [open.id] }

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
                    return calls == 1 ? [] : [second.id]
                }
                await expect(opened.deleted == [first.id], "the session before it is deleted")
                await expect(names(opened.skippedOpen) == [second.folderName], "a session opened during the run survives")
                let secondStillThere = await exists(store, second)
                await expect(secondStillThere, "its folder is still there")

                let missing = meta("no-such-folder", lastUsed: Date())
                let failed = await SessionCleanup.delete([missing, second], from: store) { [] }
                await expect(names(failed.failed.map(\.session)) == ["no-such-folder"], "the failure is reported")
                await expect(failed.deleted == [second.id], "one failure does not stop the batch")
            } catch {
                await expect(false, "mid-run fixture threw: \(error)")
            }
        }

        await suite("SessionCleanup: tracking sessions still opening") {
            let id = SessionID(folderName: "opening")
            var opening = SessionCleanup.OpeningSessions()
            opening.begin(id)
            opening.begin(id)
            opening.end(id)
            await expect(opening.ids == [id], "a session opened twice stays protected until both opens finish")
            opening.end(id)
            await expect(opening.ids.isEmpty, "finished opens are forgotten")
            opening.end(id)
            opening.begin(id)
            await expect(opening.ids == [id], "an extra finish can't cancel out a later open")
        }

        await suite("Sessions window: a session still opening is protected like the open one") {
            await runOpeningChecks()
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
            vm.openSessionIDs = { [open.id] }
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

            vm.clearChecked()
            await search("Filed", in: vm)
            vm.selection = .home
            vm.checkAllSelectable()
            await expect(vm.checkedSessionIDs == [filed.id], "during a search, select all takes only the results")
            vm.clearChecked()
            let elsewhere = try await store.createSession(name: "Filed elsewhere")
            await vm.refresh()
            vm.selection = .project(project.id)
            vm.checkAllSelectable()
            await expect(vm.checkedSessionIDs == [filed.id], "on a project page, a search can't reach other projects")
            vm.clearChecked()
            await search("", in: vm)
            try await store.deleteSession(elsewhere.id)
            await vm.refresh()

            vm.endSelectingSessions()
            vm.selection = .session(loose.id)
            vm.beginSelectingSessions()
            await expect(vm.selection == .home, "selecting from a session's page goes back to the full list")

            vm.selection = .project(project.id)
            vm.checkAllSelectable()
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
    private static func runOpeningChecks() async {
        let (root, store, projects) = await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let current = try await store.createSession(name: "Current")
            let opening = try await store.createSession(name: "Opening")
            let closed = try await store.createSession(name: "Closed")
            for session in [current, opening, closed] {
                try await backdate(session, to: date("2024-01-01T00:00:00Z"), in: store)
            }
            let vm = SessionsViewModel(projects: projects, store: store)
            vm.openSessionIDs = { [current.id, opening.id] }
            await vm.refresh()

            vm.beginSelectingSessions()
            await expect(vm.checkState(for: opening) == .open, "a session still opening shows as open")
            vm.toggleChecked(opening)
            await expect(vm.checkedSessionIDs.isEmpty, "a session still opening can't be ticked")
            vm.checkAllSelectable()
            await expect(vm.checkedSessionIDs == [closed.id], "select all skips both the open and the opening session")

            let match = vm.oldSessions(.oneYear, now: Date())
            await expect(names(match.sessions) == [closed.folderName], "delete old skips both")

            await vm.deleteSessions([opening, closed])
            let openingStillThere = await exists(store, opening)
            let closedStillThere = await exists(store, closed)
            await expect(openingStillThere, "a session still opening is never deleted")
            await expect(!closedStillThere, "the closed session is deleted")
            await expect(vm.deletionNotice?.title == "A session was kept", "one kept session gets a singular title")
            vm.deletionNotice = nil

            await vm.delete(current)
            await vm.delete(opening)
            let currentAfterSingle = await exists(store, current)
            let openingAfterSingle = await exists(store, opening)
            await expect(currentAfterSingle && openingAfterSingle, "single delete keeps open and opening sessions")
            await expect(vm.deletionNotice?.message.contains("Opening") == true, "single delete says why it did nothing")
            await expect(vm.errorMessage == nil, "keeping a session is not an error")

            guard let doomed = projects.create(name: "Doomed") else {
                await expect(false, "project was created")
                return
            }
            _ = try await store.setProject(doomed.id, for: current.id)
            _ = try await store.setProject(doomed.id, for: opening.id)
            let member = try await store.createSession(name: "Member", projectID: doomed.id)
            await vm.refresh()
            vm.deletionNotice = nil
            await vm.deleteProject(doomed.id, deleteSessions: true)
            let currentAfterProject = await exists(store, current)
            let openingAfterProject = await exists(store, opening)
            let memberAfterProject = await exists(store, member)
            await expect(currentAfterProject && openingAfterProject, "deleting a project keeps its open and opening sessions")
            await expect(!memberAfterProject, "the project's other sessions are deleted")
            await expect(projects.project(id: doomed.id) == nil, "the project itself is gone")
            await expect(vm.deletionNotice?.title == "Some sessions were kept", "two kept sessions get a plural title")
            let unfiled = await store.listSessions().filter { [current.id, opening.id].contains($0.id) }
            await expect(unfiled.allSatisfy { $0.projectID == nil }, "kept sessions become ungrouped")
        } catch {
            await expect(false, "opening fixture threw: \(error)")
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
            var openIDs: Set<SessionID> = [oldOpen.id]
            let vm = SessionsViewModel(projects: projects, store: store)
            vm.openSessionIDs = { openIDs }
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
            openIDs = []
            vm.beginSelectingSessions()
            vm.toggleChecked(oldOpen)
            let targets = vm.checkedSessions
            openIDs = [oldOpen.id]
            await vm.deleteSessions(targets)
            let openStillThere = await exists(store, oldOpen)
            await expect(openStillThere, "a session opened after picking survives")
            await expect(vm.deletionNotice?.message.contains("Old open") == true, "the user is told it was kept")

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
