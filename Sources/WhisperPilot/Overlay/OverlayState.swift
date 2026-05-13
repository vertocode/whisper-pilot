import Combine
import Foundation

/// Severity for in-app log entries.
enum LogLevel: String, Sendable, CaseIterable {
    case info, warn, error
}

struct LogEntry: Identifiable, Sendable {
    let id: UUID = UUID()
    let level: LogLevel
    let timestamp: Date
    let message: String
}

/// In-app log/alert buffer. Anything funneled through `wpInfo` / `wpWarn` / `wpError`
/// lands here, so users can see what's happening without an Xcode console attached.
@MainActor
final class LogBuffer: ObservableObject {
    static let shared = LogBuffer()

    @Published private(set) var entries: [LogEntry] = []
    /// Increments whenever a `.warn` or `.error` is appended; the overlay watches this so
    /// it can surface a numeric badge without re-rendering the full list.
    @Published private(set) var unseenAlertCount: Int = 0

    private let maxEntries = 500

    private init() {}

    func append(_ level: LogLevel, _ message: String) {
        entries.append(LogEntry(level: level, timestamp: Date(), message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        if level == .warn || level == .error {
            unseenAlertCount += 1
        }
    }

    func clearAlertBadge() {
        unseenAlertCount = 0
    }

    func clearAll() {
        entries.removeAll()
        unseenAlertCount = 0
    }
}

/// Global helpers callable from any thread. Each one `print()`s (so the message reaches
/// Xcode's console regardless of OSLog filtering) and posts an entry to `LogBuffer.shared`
/// (so the message reaches the overlay even when no console is attached).
nonisolated func wpInfo(_ message: String) {
    print("[WP] \(message)")
    Task { @MainActor in LogBuffer.shared.append(.info, message) }
}

nonisolated func wpWarn(_ message: String) {
    print("[WP][WARN] \(message)")
    Task { @MainActor in LogBuffer.shared.append(.warn, message) }
}

nonisolated func wpError(_ message: String) {
    print("[WP][ERROR] \(message)")
    Task { @MainActor in LogBuffer.shared.append(.error, message) }
}

enum OverlayStatus: Equatable, Sendable {
    case idle
    /// Pipeline is spinning up — permissions probed, audio capture being created, recognizer
    /// initializing. Lasts from Play-click until the first audio frame reaches the mixer.
    case starting
    case listening
    case thinking
    case streaming
    case needsPermission(PermissionKind)
    case needsAPIKey
    case error(String)

    var isActive: Bool {
        switch self {
        case .starting, .listening, .thinking, .streaming: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .streaming: return "Speaking"
        case .needsPermission(.microphone): return "Microphone permission needed"
        case .needsPermission(.screenRecording): return "Screen Recording permission needed"
        case .needsAPIKey: return "Add a Gemini API key in Settings"
        case .error(let message): return message
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant, system }
    enum Origin: String, Sendable {
        /// Triggered automatically by the question detector reading the transcript.
        case detectedQuestion
        /// User typed it in the composer.
        case userPrompt
        /// User pressed the "Help AI" button — manual scan-and-answer of recent
        /// transcript for an unanswered question. Acts like a typed prompt but the
        /// model is explicitly told to identify the question itself.
        case helpAI
        /// User-visible system note (e.g. "AI paused").
        case system
    }
    /// Where the message renders in the overlay. User and assistant turns always go into
    /// `.ai`; system notes use whichever section is closest to the issue they describe.
    enum Category: String, Sendable {
        /// Above both AI and transcript sections — general announcements.
        case general
        /// Inside the AI lane — assistant chat, user prompts, AI-related system notes.
        case ai
        /// Below the transcript lane — capture/recognition-related system notes.
        case transcript
    }

    let id: UUID
    let role: Role
    let origin: Origin
    var text: String
    let timestamp: Date
    var isStreaming: Bool
    var category: Category
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var status: OverlayStatus = .idle {
        didSet { statusContinuation.yield(status) }
    }
    @Published var transcript: [TranscriptSegment] = []
    @Published var permissionStatus: PermissionsSnapshot = PermissionsSnapshot()

    /// Whether the AI is currently allowed to be invoked. When paused, neither detected
    /// questions nor the auto-send timer fire — only explicit user prompts via the composer.
    @Published var isAIPaused: Bool = false
    @Published var composerText: String = ""

    /// Chronological chat history, oldest first. Trimmed to a small window so the overlay
    /// doesn't grow unbounded.
    @Published var messages: [ChatMessage] = []
    private let maxMessages = 24

    @Published var audioFrameCount: Int = 0
    @Published var transcriptCount: Int = 0

    /// Per-channel mute. When true, captured frames for that channel are dropped before
    /// reaching VAD/transcription. Capture itself keeps running so the resume is instant.
    @Published var isMicrophoneMuted: Bool = false
    @Published var isSystemAudioMuted: Bool = false

    /// User-supplied context for this session — free-form notes plus attached files.
    /// Edited via the Context dropdown in the AI lane and persisted to disk by the
    /// coordinator on every change. Surfaces in every AI prompt as authoritative
    /// background material above the live transcript.
    @Published var sessionContext: SessionContext = SessionContext()

    nonisolated let statusStream: AsyncStream<OverlayStatus>
    nonisolated private let statusContinuation: AsyncStream<OverlayStatus>.Continuation

    init() {
        var capturedContinuation: AsyncStream<OverlayStatus>.Continuation!
        self.statusStream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            capturedContinuation = continuation
        }
        self.statusContinuation = capturedContinuation
    }

    // MARK: - Chat manipulation

    @discardableResult
    func appendUserMessage(_ text: String) -> UUID {
        let msg = ChatMessage(id: UUID(), role: .user, origin: .userPrompt, text: text, timestamp: Date(), isStreaming: false, category: .ai)
        messages.append(msg)
        trim()
        return msg.id
    }

    /// Inserts a "what just fired" bubble for an auto-triggered prompt so the user can
    /// see which question was picked up by the detector or what was asked by Help AI.
    /// The actual AI reply still appears below it as a separate streaming assistant
    /// bubble. Intended origins: `.detectedQuestion`, `.helpAI`.
    @discardableResult
    func appendAutoTriggerPreamble(origin: ChatMessage.Origin, text: String) -> UUID {
        let msg = ChatMessage(id: UUID(), role: .user, origin: origin, text: text, timestamp: Date(), isStreaming: false, category: .ai)
        messages.append(msg)
        trim()
        return msg.id
    }

    @discardableResult
    func beginAssistantStream(origin: ChatMessage.Origin) -> UUID {
        let msg = ChatMessage(id: UUID(), role: .assistant, origin: origin, text: "", timestamp: Date(), isStreaming: true, category: .ai)
        messages.append(msg)
        trim()
        return msg.id
    }

    func appendDelta(to id: UUID, _ delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text.append(delta)
    }

    func finishAssistant(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isStreaming = false
    }

    @discardableResult
    func appendSystemNote(_ text: String, category: ChatMessage.Category = .general) -> UUID {
        let msg = ChatMessage(id: UUID(), role: .system, origin: .system, text: text, timestamp: Date(), isStreaming: false, category: category)
        messages.append(msg)
        trim()
        return msg.id
    }

    func clearChat() {
        messages.removeAll()
    }

    func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private func trim() {
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }
}
