import AppKit
import SwiftUI

/// Renders the brand logo with a graceful fallback to an SF Symbol when the asset catalog
/// hasn't been recompiled yet (e.g. stale DerivedData after a fresh imageset add). Avoids
/// the `No image named 'WhisperPilotLogo' found in asset catalog` console warning that
/// scares contributors.
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            content
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandLogo()
                .frame(width: 18, height: 18)

            StatusDot(status: state.status)

            Text(state.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(action: actions.toggleListening) {
                Image(systemName: state.status.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(state.status.isActive ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            .help(state.status.isActive ? "Stop listening" : "Start listening")

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
            .help("Hide overlay (re-open from the menu bar icon)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = bannerSpec {
                        BannerView(spec: banner)
                            .id("banner")
                    }
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
            // -3801 specifically means TCC denied. Steer the user to the same recovery path.
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
                .fill(Color.blue.opacity(0.10))
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
