import Combine
import Foundation

enum OverlayStatus: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case streaming
    case needsPermission(PermissionKind)
    case needsAPIKey
    case error(String)

    var isActive: Bool {
        switch self {
        case .listening, .thinking, .streaming: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
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
        /// Periodic auto-send timer (configurable interval in Settings).
        case autoSend
        /// User typed it in the composer.
        case userPrompt
        /// User-visible system note (e.g. "AI paused").
        case system
    }

    let id: UUID
    let role: Role
    let origin: Origin
    var text: String
    let timestamp: Date
    var isStreaming: Bool
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
        let msg = ChatMessage(id: UUID(), role: .user, origin: .userPrompt, text: text, timestamp: Date(), isStreaming: false)
        messages.append(msg)
        trim()
        return msg.id
    }

    @discardableResult
    func beginAssistantStream(origin: ChatMessage.Origin) -> UUID {
        let msg = ChatMessage(id: UUID(), role: .assistant, origin: origin, text: "", timestamp: Date(), isStreaming: true)
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

    func appendSystemNote(_ text: String) {
        let msg = ChatMessage(id: UUID(), role: .system, origin: .system, text: text, timestamp: Date(), isStreaming: false)
        messages.append(msg)
        trim()
    }

    func clearChat() {
        messages.removeAll()
    }

    private func trim() {
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }
}
