import AppKit
import SwiftUI

/// Renders the brand logo with a graceful fallback to an SF Symbol when the asset catalog
/// hasn't been recompiled yet.
struct BrandLogo: View {
    var body: some View {
        if let nsImage = NSImage(named: "WhisperPilotLogo") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState
    let actions: OverlayActions
    @ObservedObject private var logBuffer = LogBuffer.shared
    @FocusState private var composerFocused: Bool
    @State private var includeScreenshot: Bool = false
    @State private var showDebugPanel: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            if showDebugPanel {
                debugPanel
                Divider().opacity(0.25)
            }
            content
            Divider().opacity(0.25)
            composer
        }
        .frame(minWidth: 380, minHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: actions.goToSessions) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to Sessions (stops listening)")

            BrandLogo()
                .frame(width: 18, height: 18)

            StatusDot(status: state.status)

            VStack(alignment: .leading, spacing: 0) {
                Text(state.status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if state.status.isActive {
                    Text("\(state.audioFrameCount) audio · \(state.transcriptCount) transcripts")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Button(action: actions.toggleListening) {
                Image(systemName: state.status.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(state.status.isActive ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            .help(state.status.isActive ? "Stop listening" : "Start listening")

            Button {
                showDebugPanel.toggle()
                if showDebugPanel { logBuffer.clearAlertBadge() }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: showDebugPanel ? "ladybug.fill" : "ladybug")
                        .font(.system(size: 14))
                        .foregroundStyle(showDebugPanel ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    if logBuffer.unseenAlertCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(logBuffer.unseenAlertCount > 0
                  ? "Diagnostics (\(logBuffer.unseenAlertCount) new alert\(logBuffer.unseenAlertCount == 1 ? "" : "s"))"
                  : "Diagnostics / debug log")

            Button(action: actions.openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button(action: actions.hideOverlay) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide overlay")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Debug panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("Diagnostics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { logBuffer.clearAll() }
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let recent = logBuffer.entries.suffix(60)
                    if recent.isEmpty {
                        Text("No log entries yet — start listening to see audio + AI events.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(recent) { entry in
                            LogRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 160)
        }
        .background(Color.gray.opacity(0.06))
    }

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = bannerSpec {
                        BannerView(spec: banner)
                            .id("banner")
                    }

                    // General system notes — anything not specific to AI or transcript.
                    ForEach(generalNotes) { note in
                        MessageBubble(message: note, onDismiss: { actions.dismissMessage(note.id) })
                            .id(note.id)
                    }

                    ChatLane(
                        messages: aiMessages,
                        isAIPaused: state.isAIPaused,
                        onToggleAI: actions.toggleAIPaused,
                        onDismissMessage: actions.dismissMessage
                    )
                    .id("chat")

                    TranscriptLane(segments: state.transcript)
                        .id("transcript")

                    // Transcript-related system notes (audio/recognition watchdog, …).
                    ForEach(transcriptNotes) { note in
                        MessageBubble(message: note, onDismiss: { actions.dismissMessage(note.id) })
                            .id(note.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: state.messages.last?.id) { _, _ in
                if let last = state.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.messages.last?.text) { _, _ in
                if let last = state.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var generalNotes: [ChatMessage] {
        state.messages.filter { $0.category == .general }
    }

    private var aiMessages: [ChatMessage] {
        state.messages.filter { $0.category == .ai }
    }

    private var transcriptNotes: [ChatMessage] {
        state.messages.filter { $0.category == .transcript }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ask the AI… (uses live transcript and chat history as context)", text: $state.composerText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($composerFocused)
                    .onSubmit { submit() }

                Button(action: submit) {
                    let isEmpty = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send to AI (⌘⏎)")
            }

            Button(action: { includeScreenshot.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: includeScreenshot ? "eye.fill" : "eye")
                        .font(.system(size: 11))
                    Text("See my screen")
                        .font(.system(size: 10))
                    if includeScreenshot {
                        Text("· attached")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(includeScreenshot ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
                )
                .foregroundStyle(includeScreenshot ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .buttonStyle(.plain)
            .help("When on, the AI receives a screenshot of your current display along with this message.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submit() {
        let text = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.sendUserPrompt(text, includeScreenshot)
        state.composerText = ""
        includeScreenshot = false
    }

    // MARK: - Banner

    private var bannerSpec: BannerSpec? {
        switch state.status {
        case .needsAPIKey:
            return BannerSpec(
                message: "Add your Gemini API key in Settings to start receiving suggestions.",
                button: BannerButton(title: "Open Settings", action: actions.openSettings)
            )
        case .needsPermission(.microphone):
            return BannerSpec(
                message: "Microphone permission is required. Grant it in System Settings → Privacy & Security → Microphone.",
                button: nil
            )
        case .needsPermission(.screenRecording):
            return BannerSpec(
                message: "Screen Recording permission is required to capture meeting audio. macOS may have recorded a previous denial — open System Settings, remove any 'Whisper Pilot' entries, then run again.",
                button: BannerButton(title: "Open Privacy Settings", action: actions.openScreenRecordingPrivacy)
            )
        case .error(let message):
            if message.contains("-3801") || message.contains("declined TCCs") {
                return BannerSpec(
                    message: "macOS denied screen recording. Open Privacy Settings, remove any 'Whisper Pilot' entries, then run again.",
                    button: BannerButton(title: "Open Privacy Settings", action: actions.openScreenRecordingPrivacy)
                )
            }
            return BannerSpec(message: message, button: nil)
        default:
            return nil
        }
    }
}

struct BannerSpec {
    let message: String
    let button: BannerButton?
}

struct BannerButton {
    let title: String
    let action: () -> Void
}

private struct BannerView: View {
    let spec: BannerSpec

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let button = spec.button {
                    Button(button.title, action: button.action)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct StatusDot: View {
    let status: OverlayStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: pulse)
    }

    private var color: Color {
        switch status {
        case .idle: return .gray
        case .listening: return .green
        case .thinking: return .yellow
        case .streaming: return .blue
        case .needsPermission, .needsAPIKey: return .orange
        case .error: return .red
        }
    }

    private var opacity: Double { pulse ? 0.5 : 1.0 }

    private var pulse: Bool {
        switch status {
        case .listening, .thinking, .streaming: return true
        default: return false
        }
    }
}

private struct ChatLane: View {
    let messages: [ChatMessage]
    let isAIPaused: Bool
    let onToggleAI: () -> Void
    let onDismissMessage: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("AI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                AIToggleButton(isPaused: isAIPaused, action: onToggleAI)
            }

            if messages.isEmpty {
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(messages) { message in
                    MessageBubble(message: message, onDismiss: { onDismissMessage(message.id) })
                        .id(message.id)
                }
            }
        }
    }

    private var emptyStateText: String {
        if isAIPaused {
            return "AI is paused. Type a prompt below — manual prompts always go through."
        }
        return "No AI messages yet. Detected questions and the composer below will appear here."
    }
}

private struct AIToggleButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isPaused ? "pause.fill" : "play.fill")
                    .font(.system(size: 9))
                Text(isPaused ? "Paused" : "Active")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isPaused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((isPaused ? Color.orange : Color.green).opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((isPaused ? Color.orange : Color.green).opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(isPaused
              ? "AI is paused. Click to resume — detected questions and auto-send will fire again."
              : "AI is active. Click to pause auto-calls. Manual composer prompts always go through.")
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: roleIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(roleColor)
                Text(roleLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(roleColor)
                if let originBadge {
                    Text(originBadge)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if message.isStreaming {
                    TypingIndicator()
                }
                Spacer()
                // System notes are informational — the user should be able to clear them
                // when they've read them. Other roles persist (chat history is meaningful).
                if message.role == .system, let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 12))
                .foregroundStyle(message.role == .system ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bubbleBackground)
        )
    }

    private var roleIcon: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .system: return "info.circle"
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return .purple
        case .assistant: return .blue
        case .system: return .secondary
        }
    }

    private var originBadge: String? {
        switch message.origin {
        case .detectedQuestion: return "from detected question"
        case .autoSend: return "auto-send"
        case .userPrompt: return nil
        case .system: return nil
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return Color.purple.opacity(0.10)
        case .assistant: return Color.blue.opacity(0.08)
        case .system: return Color.gray.opacity(0.10)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(timeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var timeString: String {
        Self.timeFormatter.string(from: entry.timestamp)
    }

    private var symbol: String {
        switch entry.level {
        case .info: return "•"
        case .warn: return "⚠"
        case .error: return "✘"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 4, height: 4)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .foregroundStyle(.secondary)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
