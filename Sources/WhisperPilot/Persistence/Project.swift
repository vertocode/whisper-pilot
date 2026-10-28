import Foundation
import OSLog

/// A folder of related sessions (e.g. "Weekly com Daniel") with its own instructions and
/// context files, like a Claude.ai Project. Sessions point at a project through
/// `SessionMeta.projectID`; the project itself never owns session data, so removing a
/// project can never remove a transcript.
struct Project: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// Free-text guidance sent with every AI prompt in this project's sessions.
    var instructions: String
    var files: [ContextFile]
    /// When true, summaries of earlier sessions in the project are added to the prompt.
    var usesPriorSessions: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        files: [ContextFile] = [],
        usesPriorSessions: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.files = files
        self.usesPriorSessions = usesPriorSessions
        self.createdAt = createdAt
    }

    // Tolerant decoding: a file written by an older or newer build with a missing
    // key still loads instead of making every project disappear.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled project"
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        files = try c.decodeIfPresent([ContextFile].self, forKey: .files) ?? []
        usesPriorSessions = try c.decodeIfPresent(Bool.self, forKey: .usesPriorSessions) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Instructions and files in the shape `ContextDropdown` edits. The notes box maps
    /// to the project's instructions.
    var context: SessionContext {
        get { SessionContext(customText: instructions, files: files) }
        set {
            instructions = newValue.customText
            files = newValue.files
        }
    }

    /// Block for the AI prompt. Nil when the project has no instructions or files.
    var promptBlock: String? {
        var sections: [String] = []
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append("Project instructions:\n\(trimmed)")
        }
        for file in files {
            sections.append("Project file `\(file.filename)`:\n```\n\(file.content)\n```")
        }
        guard !sections.isEmpty else { return nil }
        return "Project \"\(name)\"\n\n" + sections.joined(separator: "\n\n")
    }
}

/// On-disk shape of `projects.json`. The version lets a later build change the layout
/// and still recognise (and migrate) files written by this one.
struct ProjectsFile: Codable, Sendable {
    var schemaVersion: Int
    var projects: [Project]
}

/// Reads and writes `<App Support>/<bundle>/projects.json`, one level above the session
/// folders (next to `global-context.json`). Also owns the one-time storage migration.
actor ProjectStorage {
    static let shared = ProjectStorage(
        directory: SessionStore.shared.rootURL.deletingLastPathComponent(),
        sessionsDirectory: SessionStore.shared.rootURL
    )

    static let currentSchemaVersion = 1

    private let directory: URL
    private let sessionsDirectory: URL
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "ProjectStorage")

    init(directory: URL, sessionsDirectory: URL) {
        self.directory = directory
        self.sessionsDirectory = sessionsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var projectsURL: URL { directory.appendingPathComponent("projects.json") }
    private var markerURL: URL { directory.appendingPathComponent("storage-version.json") }
    var backupDirectory: URL {
        directory.appendingPathComponent("backups").appendingPathComponent("pre-projects")
    }

    /// Runs the migration if needed, then returns the saved projects.
    func load() -> [Project] {
        migrateIfNeeded()
        guard let data = try? Data(contentsOf: projectsURL) else { return [] }
        if let file = try? Self.decoder.decode(ProjectsFile.self, from: data) {
            return file.projects
        }
        // Unreadable file: keep a copy before a later save replaces it.
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = directory.appendingPathComponent("projects.unreadable-\(stamp).json")
        try? data.write(to: copy, options: .atomic)
        log.error("projects.json could not be read; saved a copy as \(copy.lastPathComponent, privacy: .public)")
        return []
    }

    func save(_ projects: [Project]) throws {
        let file = ProjectsFile(schemaVersion: Self.currentSchemaVersion, projects: projects)
        let data = try Self.encoder.encode(file)
        try data.write(to: projectsURL, options: .atomic)
    }

    /// Version 1 adds projects. Existing sessions need no rewrite: the new metadata
    /// fields are optional and old files decode as "no project". As a safety net the
    /// first run copies every `metadata.json` aside, then drops a marker so it never
    /// runs again. Nothing is moved, rewritten or deleted.
    func migrateIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: markerURL.path) else { return }
        let names = (try? manager.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        try? manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        var copied = 0
        var failed = 0
        for name in names {
            let source = sessionsDirectory.appendingPathComponent(name).appendingPathComponent("metadata.json")
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = backupDirectory.appendingPathComponent("\(name).metadata.json")
            if manager.fileExists(atPath: target.path) { continue }
            do {
                try manager.copyItem(at: source, to: target)
                copied += 1
            } catch {
                failed += 1
            }
        }
        // A failed copy leaves the marker out so the next launch tries again.
        guard failed == 0 else {
            log.error("Migration backup incomplete (\(failed) failed); will retry next launch")
            return
        }
        let marker = ["version": Self.currentSchemaVersion]
        if let data = try? JSONSerialization.data(withJSONObject: marker) {
            try? data.write(to: markerURL, options: .atomic)
        }
        log.info("Storage migrated to v\(Self.currentSchemaVersion); backed up \(copied) session metadata files")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
