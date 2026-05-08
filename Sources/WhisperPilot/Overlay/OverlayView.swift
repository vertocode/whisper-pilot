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
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
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

            Button(action: actions.toggleAIPaused) {
                Image(systemName: state.isAIPaused ? "sparkles.slash" : "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(state.isAIPaused ? .orange : .blue)
            }
            .buttonStyle(.plain)
            .help(state.isAIPaused ? "Resume AI (auto-suggestions)" : "Pause AI (no auto-calls; manual prompts still work)")

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

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = bannerSpec {
                        BannerView(spec: banner)
                            .id("banner")
                    }

                    if !state.messages.isEmpty {
                        ChatLane(messages: state.messages)
                            .id("chat")
                    }

                    TranscriptLane(segments: state.transcript)
                        .id("transcript")
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

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask the AI… (uses live transcript as context)", text: $state.composerText, axis: .vertical)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submit() {
        let text = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.sendUserPrompt(text)
        state.composerText = ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(messages) { message in
                MessageBubble(message: message)
                    .id(message.id)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

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
