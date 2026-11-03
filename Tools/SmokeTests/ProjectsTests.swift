import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
    }

    static func runProjectsSuite() async {
        await suite("Projects: migration keeps every existing session") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
            let store = SessionStore(baseURL: sessionsDir)
            do {
                // An old-format session: metadata written before projects existed.
                let old = try await store.createSession(name: "Old weekly")
                // Appending touches metadata.json, so do it before writing the old file.
                await store.appendTranscriptLine(channel: .system, text: "hello there", at: Date(), to: old.id)
                let oldMeta = """
                {"folderName":"\(old.folderName)","displayName":"Old weekly","createdAt":"2025-01-01T10:00:00Z","lastUsedAt":"2025-01-02T10:00:00Z","selectedModel":"x"}
                """
                let metaURL = sessionsDir.appendingPathComponent(old.folderName).appendingPathComponent("metadata.json")
                try Data(oldMeta.utf8).write(to: metaURL)
                let transcriptBefore = await store.loadTranscriptMarkdown(old.id)

                let storage = ProjectStorage(directory: root, sessionsDirectory: sessionsDir)
                let projects = await storage.load()
                await expect(projects.isEmpty, "first load has no projects")

                let backup = await storage.backupDirectory.appendingPathComponent("\(old.folderName).metadata.json")
                await expect(FileManager.default.fileExists(atPath: backup.path), "metadata backed up before use")
                let after = (try? Data(contentsOf: metaURL)).map { String(decoding: $0, as: UTF8.self) }
                await expect(after == oldMeta, "migration does not rewrite session metadata")

                let listed = await store.listSessions()
                await expect(listed.count == 1 && listed[0].displayName == "Old weekly", "old session still lists")
                await expect(listed[0].projectID == nil && listed[0].titleSource == nil, "old session is ungrouped")
                await expect(listed[0].selectedModel == "x", "old fields survive decoding")
                let transcriptAfter = await store.loadTranscriptMarkdown(old.id)
                await expect(transcriptBefore == transcriptAfter, "transcript untouched")

                // Running again changes nothing.
                try Data("changed".utf8).write(to: metaURL)
                await storage.migrateIfNeeded()
                let backupText = (try? Data(contentsOf: backup)).map { String(decoding: $0, as: UTF8.self) }
                await expect(backupText == oldMeta, "migration runs once and does not overwrite the backup")
            } catch {
                await expect(false, "migration setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Projects: storage round trip and damaged file") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
            let storage = ProjectStorage(directory: root, sessionsDirectory: sessionsDir)
            do {
                var project = Project(name: "Weekly com Daniel", instructions: "Keep answers short")
                project.files = [ContextFile(id: UUID(), filename: "a.md", sourcePath: "/a.md", content: "hi", byteCount: 2, attachedAt: Date())]
                try await storage.save([project])
                let loaded = await storage.load()
                await expect(loaded.count == 1 && loaded[0].name == "Weekly com Daniel", "project round trips")
                await expect(loaded[0].instructions == "Keep answers short" && loaded[0].files.count == 1, "instructions and files round trip")
                await expect(loaded[0].usesPriorSessions, "prior sessions default on")

                try Data("{nope".utf8).write(to: root.appendingPathComponent("projects.json"))
                let damaged = await storage.load()
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                await expect(damaged.isEmpty, "damaged file loads as empty")
                await expect(names.contains { $0.hasPrefix("projects.unreadable-") }, "damaged file is copied aside")

                let sparse = #"{"schemaVersion":1,"projects":[{"id":"\#(UUID().uuidString)"}]}"#
                try Data(sparse.utf8).write(to: root.appendingPathComponent("projects.json"))
                let tolerant = await storage.load()
                await expect(tolerant.count == 1 && tolerant[0].usesPriorSessions, "missing keys use defaults")
            } catch {
                await expect(false, "storage setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Projects: assigning sessions and deleting a project") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let projectID = UUID()
                let inProject = try await store.createSession(name: "A", projectID: projectID)
                let other = try await store.createSession(name: "B")
                await expect(inProject.projectID == projectID, "new session starts in project")

                let moved = try await store.setProject(projectID, for: other.id)
                await expect(moved?.projectID == projectID, "session moves into project")
                let removed = await store.clearProject(projectID)
                await expect(removed == 2, "clearing a project reports both sessions")
                let listed = await store.listSessions()
                await expect(listed.count == 2, "no session is lost when a project goes away")
                await expect(listed.allSatisfy { $0.projectID == nil }, "sessions become ungrouped")

                // A damaged metadata file is refused, not overwritten.
                let url = root.appendingPathComponent(other.folderName).appendingPathComponent("metadata.json")
                try Data("{broken".utf8).write(to: url)
                var threw = false
                do { _ = try await store.setProject(projectID, for: other.id) } catch { threw = true }
                await expect(threw, "unreadable metadata is not overwritten by a move")
                await expect((try? Data(contentsOf: url)) == Data("{broken".utf8), "damaged file left as it was")
            } catch {
                await expect(false, "assignment setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Auto-title: never overwrites a manual title") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let untitled = try await store.createSession(name: nil)
                await expect(untitled.canAutoTitle, "unnamed session can be auto-titled")
                let titled = await store.applyAutoTitle("Quarterly planning", to: untitled.id)
                await expect(titled?.displayName == "Quarterly planning" && titled?.titleSource == .auto, "auto title saved")

                let named = try await store.createSession(name: "My own name")
                await expect(!named.canAutoTitle, "named session is protected")
                let blocked = await store.applyAutoTitle("Something else", to: named.id)
                await expect(blocked == nil, "auto title refused for a named session")

                // The user renames while the AI is still thinking.
                let race = try await store.createSession(name: nil)
                _ = try await store.renameSession(race.id, to: "Untitled session")
                let afterRename = await store.applyAutoTitle("AI title", to: race.id)
                await expect(afterRename == nil, "a rename, even back to the placeholder, is a user title")

                let names = await store.listSessions().map(\.displayName).sorted()
                await expect(names == ["My own name", "Quarterly planning", "Untitled session"], "titles on disk are as expected")
            } catch {
                await expect(false, "auto-title setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Auto-title: parsing the model reply") {
            let ok = SessionTitler.parse("TITLE: \"Weekly sync with Daniel.\"\nSUMMARY: They covered hiring.\nNext step is a decision on Friday.")
            await expect(ok.title == "Weekly sync with Daniel", "quotes and period stripped")
            await expect(ok.summary == "They covered hiring. Next step is a decision on Friday.", "multi-line summary joined")

            let styled = SessionTitler.parse("**Title:** Budget review\n**Summary:** Short.")
            await expect(styled.title == "Budget review" && styled.summary == "Short.", "bold labels accepted")

            let junk = SessionTitler.parse("Sure! Here you go.")
            await expect(junk.title == nil && junk.summary == nil, "unusable reply gives nothing")

            let long = SessionTitler.cleanTitle(String(repeating: "word ", count: 40))
            await expect((long?.count ?? 0) <= SessionTitler.maxTitleLength, "long title is cut")
            await expect(SessionTitler.cleanTitle("  \"\"  ") == nil, "empty title rejected")

            let md = "# Transcript\n\n_Captured live._\n\n**Other** [14:02:11] Welcome all.\n> pt-BR — Bem-vindos\n\n**Me** [14:02:18] Thanks.\n"
            await expect(SessionTitler.plainTranscript(md) == "Other: Welcome all.\nMe: Thanks.", "markdown turned into plain lines")
        }

        await suite("Projects: prompt context and history budget") {
            let project = Project(name: "Weekly", instructions: "Answer in Portuguese")
            await expect(project.promptBlock?.contains("Answer in Portuguese") == true, "instructions in block")
            await expect(Project(name: "Empty").promptBlock == nil, "empty project adds nothing")

            let now = Date()
            let entries = [
                ProjectHistory.Entry(title: "Newest", date: now, text: String(repeating: "n", count: 600)),
                ProjectHistory.Entry(title: "Older", date: now.addingTimeInterval(-86_400), text: String(repeating: "o", count: 600)),
                ProjectHistory.Entry(title: "Oldest", date: now.addingTimeInterval(-172_800), text: String(repeating: "x", count: 600))
            ]
            let block = ProjectHistory.block(entries: entries, budget: 900) ?? ""
            await expect(block.contains("Newest"), "most recent session kept first")
            await expect(!block.contains("Oldest"), "oldest dropped when over budget")
            await expect(block.count <= 900, "history stays within budget")
            await expect(ProjectHistory.block(entries: [], budget: 900) == nil, "no history gives no block")

            var snapshot = ConversationSnapshot(recentLines: ["Other: hi"], topics: [], entities: [])
            snapshot.projectContextBlock = project.promptBlock
            snapshot.projectHistoryBlock = block
            let prompt = PromptBuilder.build(context: snapshot, history: [], question: "What now?", style: .concise)
            await expect(prompt.context.contains("Answer in Portuguese"), "project instructions reach the prompt")
            await expect(prompt.stableContext.contains("Earlier sessions in this project"), "history is in the cacheable part")
        }

        await suite("Projects: creating during first load keeps saved projects") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
            let storage = ProjectStorage(directory: root, sessionsDirectory: sessionsDir)
            do {
                try await storage.save([Project(name: "Existing", instructions: "keep me")])
                let store = await ProjectsStore(storage: storage)
                await store.create(name: "Brand new")
                await store.flush()
                let onDisk = await storage.load()
                let names = onDisk.map(\.name).sorted()
                await expect(names == ["Brand new", "Existing"], "both projects are on disk")
                await expect(onDisk.first { $0.name == "Existing" }?.instructions == "keep me", "old instructions survive")
            } catch {
                await expect(false, "store setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Projects: Other speaker stays out of history and recaps") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let markdown = "**Me** [10:00:00] my line\n**Other** [10:00:05] secret line\n> pt-BR — linha secreta\n**Me** [10:00:09] again"
                let stripped = SessionStore.strippingOtherSpeaker(markdown)
                await expect(!stripped.contains("secret") && !stripped.contains("secreta"), "Other lines and their translations are removed")
                await expect(stripped.contains("my line") && stripped.contains("again"), "Me lines are kept")

                let projectID = UUID()
                let older = try await store.createSession(name: "Older", projectID: projectID)
                await store.appendTranscriptLine(channel: .system, text: "secret line", at: Date(), to: older.id)
                await store.appendTranscriptLine(channel: .microphone, text: "my line", at: Date(), to: older.id)
                let current = try await store.createSession(name: "Now", projectID: projectID)

                let withOther = await store.projectHistoryEntries(projectID: projectID, excluding: current.id)
                await expect(withOther.first?.text.contains("secret line") == true, "Other is used when allowed")
                let without = await store.projectHistoryEntries(projectID: projectID, excluding: current.id, includeOther: false)
                await expect(without.first?.text.contains("secret line") == false, "fallback drops Other when excluded")

                await store.saveSummary(SessionSummary(summary: "mixed recap", transcriptBytes: 1, generatedAt: Date(), excludesOther: nil), for: older.id)
                let mixed = await store.projectHistoryEntries(projectID: projectID, excluding: current.id, includeOther: false)
                await expect(mixed.first?.text.contains("mixed recap") == false, "old recap is not reused when Other is excluded")
                await store.saveSummary(SessionSummary(summary: "safe recap", transcriptBytes: 1, generatedAt: Date(), excludesOther: true), for: older.id)
                let safe = await store.projectHistoryEntries(projectID: projectID, excluding: current.id, includeOther: false)
                await expect(safe.first?.text == "safe recap", "recap written without Other is reused")
            } catch {
                await expect(false, "history setup failed: \(error.localizedDescription)")
            }
        }

        await suite("Projects: search across title and transcript") {
            let root = tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let a = try await store.createSession(name: "One")
                let b = try await store.createSession(name: "Two")
                await store.appendTranscriptLine(channel: .system, text: "We discussed the Orçamento today", at: Date(), to: a.id)
                await store.saveSummary(SessionSummary(summary: "Talked about hiring plans", transcriptBytes: 1, generatedAt: Date()), for: b.id)
                let byTranscript = await store.sessionsMatchingContent("orcamento")
                await expect(byTranscript == [a.folderName], "transcript match ignores case and accents")
                let bySummary = await store.sessionsMatchingContent("HIRING")
                await expect(bySummary == [b.folderName], "summary match")
                let none = await store.sessionsMatchingContent("zzz")
                await expect(none.isEmpty, "no match")
            } catch {
                await expect(false, "search setup failed: \(error.localizedDescription)")
            }
        }
    }
}

extension SmokeTestRunner {
    static func runFreezeSafetySuite() async {
        await suite("HardCeiling: pure thresholds") {
            let config = HardCeilingConfig.default
            func sample(cpu: Double = 20, mem: UInt64 = 500_000_000) -> ResourceSample {
                ResourceSample(cpuPercent: cpu, memoryBytes: mem, thermalState: .nominal)
            }

            await expect(config.footprintBytes == 2_250_000_000, "memory ceiling is 2.25 GB")
            await expect(config.cpuPercent == 300 && config.cpuSustainSeconds == 60, "CPU ceiling is 300% for 60 s")

            do {
                var ceiling = HardCeiling(config: config)
                var tripped = false
                var t = 0.0
                while t <= 3600 {
                    if ceiling.evaluate(sample(cpu: 180, mem: 1_700_000_000), at: t) != nil { tripped = true }
                    t += 1
                }
                await expect(!tripped, "an hour of heavy but normal load never trips the ceiling")
            }

            do {
                var ceiling = HardCeiling(config: config)
                let over = config.footprintBytes + 1
                await expect(ceiling.evaluate(sample(mem: over), at: 0) == nil, "first sample over the memory ceiling waits")
                await expect(ceiling.evaluate(sample(mem: over), at: 1) == nil, "still inside the memory grace time")
                await expect(ceiling.evaluate(sample(mem: over), at: config.footprintSustainSeconds) == .memory,
                             "memory held over the ceiling trips")
            }

            do {
                var ceiling = HardCeiling(config: config)
                let over = config.footprintBytes + 1
                _ = ceiling.evaluate(sample(mem: over), at: 0)
                _ = ceiling.evaluate(sample(mem: 800_000_000), at: 1)
                _ = ceiling.evaluate(sample(mem: over), at: 2)
                await expect(ceiling.evaluate(sample(mem: over), at: 4) == nil, "a short memory spike restarts the clock")
            }

            do {
                var ceiling = HardCeiling(config: config)
                _ = ceiling.evaluate(sample(cpu: 400), at: 0)
                await expect(ceiling.evaluate(sample(cpu: 400), at: 59) == nil, "CPU over the ceiling for 59 s does not trip")
                await expect(ceiling.evaluate(sample(cpu: 400), at: 60) == .cpu, "CPU over the ceiling for 60 s trips")
            }

            do {
                var ceiling = HardCeiling(config: config)
                _ = ceiling.evaluate(sample(cpu: 400), at: 0)
                _ = ceiling.evaluate(sample(cpu: 400), at: 30)
                for t in 31...34 { _ = ceiling.evaluate(sample(cpu: 50), at: Double(t)) }
                _ = ceiling.evaluate(sample(cpu: 400), at: 35)
                await expect(ceiling.evaluate(sample(cpu: 400), at: 94) == nil, "a dip longer than the tolerance restarts the CPU clock")
                await expect(ceiling.evaluate(sample(cpu: 400), at: 95) == .cpu, "the restarted clock still trips after 60 s")
            }

            do {
                var ceiling = HardCeiling(config: config)
                _ = ceiling.evaluate(sample(cpu: 400), at: 0)
                _ = ceiling.evaluate(sample(cpu: 400), at: 30)
                _ = ceiling.evaluate(sample(cpu: 50), at: 31)
                await expect(ceiling.evaluate(sample(cpu: 400), at: 60) == .cpu, "a one-second dip does not reset the CPU clock")
            }
        }

        await suite("Prior-session context caps") {
            func entry(_ n: Int, chars: Int) -> ProjectHistory.Entry {
                ProjectHistory.Entry(title: "S\(n)", date: Date(timeIntervalSince1970: Double(n) * 86_400), text: String(repeating: "x", count: chars))
            }

            let many = (0..<40).map { entry($0, chars: 100) }
            let block = ProjectHistory.block(entries: many, budget: 1_000_000) ?? ""
            await expect(block.components(separatedBy: "### ").count - 1 == ProjectHistory.maxSessions,
                         "no more than \(ProjectHistory.maxSessions) sessions are included")

            let huge = [entry(1, chars: 50_000)]
            let single = ProjectHistory.block(entries: huge, budget: 1_000_000) ?? ""
            await expect(single.count < ProjectHistory.maxEntryCharacters + 100, "one session's text is cut to the per-entry cap")

            let bulky = (0..<40).map { entry($0, chars: 5_000) }
            let total = ProjectHistory.block(entries: bulky, budget: 1_000_000) ?? ""
            await expect(total.count <= ProjectHistory.maxTotalCharacters, "the whole block never passes the total cap")

            let tight = ProjectHistory.block(entries: bulky, budget: 3_000) ?? ""
            await expect(tight.count <= 3_000, "a smaller budget still wins")

            let files = (0..<20).map {
                ContextFile(id: UUID(), filename: "f\($0).md", sourcePath: "/f\($0).md",
                            content: String(repeating: "y", count: 150_000), byteCount: 150_000, attachedAt: Date())
            }
            let project = Project(name: "Big", instructions: "be brief", files: files)
            let promptBlock = project.promptBlock ?? ""
            await expect(promptBlock.count <= SessionContext.maxPromptCharacters + 100,
                         "a project with 20 large files still builds a bounded prompt block")
            let session = SessionContext(customText: "", files: files).promptBlock ?? ""
            await expect(session.count <= SessionContext.maxPromptCharacters, "a session context is bounded too")
            await expect(SessionContext.joinBounded([]) == nil, "no sections give no block")

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let project = UUID()
                let target = try await store.createSession(name: "Target", projectID: project)
                var ids: [SessionID] = []
                for i in 0..<12 {
                    let meta = try await store.createSession(name: "Earlier \(i)", projectID: project)
                    for line in 0..<5 {
                        await store.appendTranscriptLine(channel: .microphone, text: "line \(line) of session \(i)", at: Date(), to: meta.id)
                    }
                    ids.append(meta.id)
                }
                let entries = await store.projectHistoryEntries(projectID: project, excluding: target.id, limit: 100)
                await expect(entries.count == ProjectHistory.maxSessions, "history loads at most \(ProjectHistory.maxSessions) sessions, even if asked for more")

                let long = ids[0]
                for line in 0..<3_000 {
                    await store.appendTranscriptLine(channel: .microphone, text: "filler sentence number \(line) for a long meeting", at: Date(), to: long)
                }
                let tail = await store.loadTranscriptTail(long, bytes: 2_000)
                await expect(tail.utf8.count <= 2_000, "tail read returns no more than asked")
                await expect(tail.contains("number 2999"), "tail read keeps the end of the transcript")
                await expect(tail.hasPrefix("**"), "tail read starts on a whole line")
                let short = await store.loadTranscriptTail(ids[1], bytes: 100_000)
                await expect(short.contains("line 0 of session 1"), "tail read of a short file returns everything")
            } catch {
                await expect(false, "history cap fixture threw: \(error)")
            }
        }
    }
}
