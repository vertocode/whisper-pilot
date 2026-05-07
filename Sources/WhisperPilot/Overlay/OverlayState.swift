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

@MainActor
final class OverlayState: ObservableObject {
    @Published var status: OverlayStatus = .idle {
        didSet { statusContinuation.yield(status) }
    }
    @Published var transcript: [TranscriptSegment] = []
    @Published var responseText: String = ""
    @Published var isResponseStreaming: Bool = false
    @Published var permissionStatus: PermissionsSnapshot = PermissionsSnapshot()
    @Published var pinnedSuggestions: [String] = []

    nonisolated let statusStream: AsyncStream<OverlayStatus>
    nonisolated private let statusContinuation: AsyncStream<OverlayStatus>.Continuation

    init() {
        var capturedContinuation: AsyncStream<OverlayStatus>.Continuation!
        self.statusStream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            capturedContinuation = continuation
        }
        self.statusContinuation = capturedContinuation
    }

    func beginResponse() {
        responseText = ""
        isResponseStreaming = true
        status = .streaming
    }

    func appendResponse(_ delta: String) {
        responseText.append(delta)
    }

    func endResponse() {
        isResponseStreaming = false
    }

    func clearResponse() {
        responseText = ""
        isResponseStreaming = false
    }
}
