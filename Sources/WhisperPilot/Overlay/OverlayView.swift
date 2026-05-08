import SwiftUI

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("WhisperPilotLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            StatusDot(status: state.status)
            Text(state.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !state.responseText.isEmpty || state.isResponseStreaming {
                        ResponseLane(text: state.responseText, streaming: state.isResponseStreaming)
                            .id("response")
                    }
                    TranscriptLane(segments: state.transcript)
                        .id("transcript")
                }
                .padding(12)
            }
            .onChange(of: state.responseText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("response", anchor: .top)
                }
            }
        }
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

    private var opacity: Double {
        pulse ? 0.5 : 1.0
    }

    private var pulse: Bool {
        switch status {
        case .listening, .thinking, .streaming: return true
        default: return false
        }
    }
}

private struct ResponseLane: View {
    let text: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Suggestion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if streaming {
                    TypingIndicator()
                }
            }
            Text(text.isEmpty ? "…" : text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
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
