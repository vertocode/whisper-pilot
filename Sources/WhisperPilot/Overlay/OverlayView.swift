import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the brand logo with two layered fallbacks:
///   1. The `WhisperPilotLogo` imageset from the asset catalog.
///   2. The raw `whisper-logo-nobg.png` file bundled directly (works even when
///      the asset catalog isn't compiled into the running binary).
///   3. The SF Symbol `waveform.circle.fill` as a last-ditch placeholder.
struct BrandLogo: View {
    var body: some View {
        if let nsImage = Self.loadBrandLogo() {
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

    /// Shared brand-logo loader. Used by `BrandLogo` for SwiftUI surfaces and by
    /// `MenuBarController` for the status item. Returns the best available image
    /// or `nil` if neither path resolved.
    static func loadBrandLogo() -> NSImage? {
        if let asset = NSImage(named: "WhisperPilotLogo") {
            return asset
        }
        // Asset catalog miss — happens when running outputs that don't compile
        // xcassets (e.g. `swift run` builds). Fall back to the raw PNG bundled
        // alongside the asset catalog via `Project.yml`'s `resources` list.
        if let url = Bundle.main.url(forResource: "whisper-logo-nobg", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState
    let actions: OverlayActions
    @ObservedObject private var logBuffer = LogBuffer.shared
    @FocusState private var composerFocused: Bool
    @State private var includeScreenshot: Bool = false
    @State private var showDebugPanel: Bool = false
    /// Fraction of the available split-pane height given to the AI/chat pane. The
    /// remainder goes to the transcript pane. Drag the divider to adjust; bounded
    /// to keep both panes at least `minPaneHeight` tall. Only used when both
    /// panes are expanded — collapse modes ignore it and use the lane's intrinsic
    /// header height for whichever pane is dropped.
    @State private var chatFraction: CGFloat = 0.5
    /// Fraction captured at the start of a drag gesture so we can compute the new
    /// fraction relative to the drag origin instead of accumulating per-frame deltas.
    @State private var dragStartFraction: CGFloat?
    @State private var chatCollapsed: Bool = false
    @State private var transcriptCollapsed: Bool = false

    private let dividerThickness: CGFloat = 6
    private let minPaneHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if showDebugPanel {
                debugPanel
                Divider().opacity(0.4)
            }
            content
            Divider().opacity(0.4)
            composer
        }
        .frame(minWidth: 380, minHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WP.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.xl, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .padding(WP.Space.sm)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: WP.Space.sm) {
            Button(action: actions.goToSessions) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Sessions (stops listening)")

            BrandLogo()
                .frame(width: 18, height: 18)

            HStack(spacing: 6) {
                StatusDot(status: state.status)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.status.label)
                        .font(WP.TextStyle.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if state.status.isActive {
                        Text("\(state.audioFrameCount) audio · \(state.transcriptCount) transcripts")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: WP.Space.sm)

            Button(action: actions.toggleListening) {
                if state.status == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: state.status.isActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(state.status.isActive ? Color.red : Color.accentColor)
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.status == .starting)
            .help(playButtonHelp)

            ChannelMuteButton(
                isMuted: state.isMicrophoneMuted,
                activeIcon: "mic.fill",
                mutedIcon: "mic.slash.fill",
                activeHelp: "Microphone is being transcribed. Click to mute (capture continues but isn't transcribed).",
                mutedHelp: "Microphone is muted — no transcription of your voice. Click to resume.",
                action: actions.toggleMicMute
            )

            ChannelMuteButton(
                isMuted: state.isSystemAudioMuted,
                activeIcon: "speaker.wave.2.fill",
                mutedIcon: "speaker.slash.fill",
                activeHelp: "System audio is being transcribed. Click to mute (capture continues but isn't transcribed).",
                mutedHelp: "System audio is muted — no transcription of meeting/video audio. Click to resume.",
                action: actions.toggleSystemAudioMute
            )

            Menu {
                Button(action: actions.exportTranscript) {
                    Label("Export transcript…", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("e", modifiers: [.command])
                Divider()
                Button {
                    showDebugPanel.toggle()
                    if showDebugPanel { logBuffer.clearAlertBadge() }
                } label: {
                    Label(
                        showDebugPanel ? "Hide diagnostics" : "Show diagnostics",
                        systemImage: "ladybug"
                    )
                }
                Button(action: actions.openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button(action: actions.hideOverlay) {
                    Label("Hide overlay", systemImage: "eye.slash")
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                    if logBuffer.unseenAlertCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                            .offset(x: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(logBuffer.unseenAlertCount > 0
                  ? "More (\(logBuffer.unseenAlertCount) new diagnostic alert\(logBuffer.unseenAlertCount == 1 ? "" : "s"))"
                  : "More")
        }
        .padding(.horizontal, WP.Space.md)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private var playButtonHelp: String {
        switch state.status {
        case .starting: return "Starting…"
        case .listening, .thinking, .streaming: return "Stop listening"
        default: return "Start listening"
        }
    }

    // MARK: - Debug panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: WP.Space.xs) {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: "ladybug.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("Diagnostics")
                    .font(WP.TextStyle.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mic Test") { actions.runMicTest() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Records 3s from your microphone and reports RMS energy. Proves whether the mic captures real audio (independent of the recognizer).")
                Button("Audio Test") { actions.runAudioTest() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Captures 3s of system audio via Process Tap and reports RMS energy. Proves whether your audio routing is going through the macOS mixdown we read from.")
                Button("Self-Test") { actions.runSelfTest() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Synthesizes speech and feeds it to the recognizer. Proves whether the recognition pipeline works in isolation from audio capture.")
                Button("Clear") { logBuffer.clearAll() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, WP.Space.md)
            .padding(.top, WP.Space.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let recent = logBuffer.entries.suffix(60)
                    if recent.isEmpty {
                        Text("No log entries yet — start listening to see audio and AI events appear here.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, WP.Space.md)
                            .padding(.vertical, WP.Space.xs)
                    } else {
                        ForEach(recent) { entry in
                            LogRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, WP.Space.md)
                .padding(.bottom, WP.Space.sm)
            }
            .frame(maxHeight: 160)
        }
        .background(.quinary)
    }

    // MARK: - Content

    /// The body content area. Banner + general notes live above the split because
    /// they're brief and important — the user always wants them visible. The two
    /// lanes (AI chat / live transcript) each get their own scroll view inside a
    /// resizable split so a long conversation in one doesn't push the other out of
    /// view. Dragging the divider rebalances how much space each lane gets.
    private var content: some View {
        VStack(spacing: 0) {
            if hasTopNotices {
                topNotices
                Divider().opacity(0.4)
            }
            bodyPanes
                // GeometryReader inside is flexible by nature; be explicit so the
                // outer VStack always gives this region the remaining vertical space
                // rather than collapsing it under one of the fixed-height neighbors.
                .frame(maxHeight: .infinity)
        }
    }

    /// Layout switches on which panes are collapsed:
    /// - Both expanded → GeometryReader split with a draggable divider.
    /// - One collapsed → the collapsed pane takes its intrinsic header height,
    ///   the expanded one fills the rest, divider becomes a static separator.
    /// - Both collapsed → both header bars stack at the top, rest is empty.
    /// We branch the whole layout rather than baking the modes into one
    /// GeometryReader because intrinsic-height children inside a constrained
    /// VStack get tricky to size predictably across collapse transitions.
    @ViewBuilder
    private var bodyPanes: some View {
        switch (chatCollapsed, transcriptCollapsed) {
        case (false, false):
            GeometryReader { geo in
                let available = max(geo.size.height - dividerThickness, 1)
                let fraction = clampFraction(chatFraction, available: available)
                let chatHeight = available * fraction
                VStack(spacing: 0) {
                    chatPane
                        .frame(height: chatHeight)
                    splitDivider(available: available, draggable: true)
                    transcriptPane
                        .frame(maxHeight: .infinity)
                }
            }
        case (true, false):
            VStack(spacing: 0) {
                chatPane
                splitDivider(available: 0, draggable: false)
                transcriptPane
                    .frame(maxHeight: .infinity)
            }
        case (false, true):
            VStack(spacing: 0) {
                chatPane
                    .frame(maxHeight: .infinity)
                splitDivider(available: 0, draggable: false)
                transcriptPane
            }
        case (true, true):
            VStack(spacing: 0) {
                chatPane
                splitDivider(available: 0, draggable: false)
                transcriptPane
                Spacer(minLength: 0)
            }
        }
    }

    private var hasTopNotices: Bool {
        bannerSpec != nil || !generalNotes.isEmpty
    }

    private var topNotices: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            if let banner = bannerSpec {
                BannerView(spec: banner)
            }
            ForEach(generalNotes) { note in
                MessageBubble(message: note, onDismiss: { actions.dismissMessage(note.id) })
            }
        }
        .padding(.horizontal, WP.Space.md)
        .padding(.vertical, WP.Space.sm)
    }

    /// Top pane: AI chat. Own `ScrollView` (when expanded) so transcript growth
    /// never pushes new AI messages out of view. Auto-scrolls to the latest
    /// message on new id or streamed text. When collapsed, renders only the
    /// header — no ScrollView, so a single-row pane doesn't show empty space
    /// with scroll indicators.
    @ViewBuilder
    private var chatPane: some View {
        if chatCollapsed {
            ChatLane(
                messages: aiMessages,
                isAIPaused: state.isAIPaused,
                onToggleAI: actions.toggleAIPaused,
                onDismissMessage: actions.dismissMessage,
                sessionContext: $state.sessionContext,
                isCollapsed: true,
                onToggleCollapse: { chatCollapsed.toggle() }
            )
            .padding(WP.Space.md)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    ChatLane(
                        messages: aiMessages,
                        isAIPaused: state.isAIPaused,
                        onToggleAI: actions.toggleAIPaused,
                        onDismissMessage: actions.dismissMessage,
                        sessionContext: $state.sessionContext,
                        isCollapsed: false,
                        onToggleCollapse: { chatCollapsed.toggle() }
                    )
                    .padding(WP.Space.md)
                }
                .onChange(of: aiMessages.last?.id) { _, _ in
                    guard let last = aiMessages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: aiMessages.last?.text) { _, _ in
                    guard let last = aiMessages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    /// Bottom pane: live transcript + transcript-related system notes (audio /
    /// recognition watchdogs). Own `ScrollView` (when expanded) so the latest
    /// transcript line is always visible regardless of how long the AI
    /// conversation has grown. Collapses to header-only like the chat pane.
    @ViewBuilder
    private var transcriptPane: some View {
        if transcriptCollapsed {
            TranscriptLane(
                segments: state.transcript,
                isCollapsed: true,
                onToggleCollapse: { transcriptCollapsed.toggle() }
            )
            .padding(WP.Space.md)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: WP.Space.md) {
                        TranscriptLane(
                            segments: state.transcript,
                            isCollapsed: false,
                            onToggleCollapse: { transcriptCollapsed.toggle() }
                        )
                        ForEach(transcriptNotes) { note in
                            MessageBubble(message: note, onDismiss: { actions.dismissMessage(note.id) })
                                .id(note.id)
                        }
                    }
                    .padding(WP.Space.md)
                }
                .onChange(of: state.transcript.last?.id) { _, _ in
                    guard let last = state.transcript.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: state.transcript.last?.text) { _, _ in
                    guard let last = state.transcript.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    /// Divider between the two panes. When `draggable` is true (both expanded)
    /// the hover cursor flips to the resize indicator and a vertical drag
    /// rebalances `chatFraction`. When one pane is collapsed, the divider is a
    /// static separator with no interactive behavior — there's nothing
    /// meaningful to resize while the other pane is at a fixed intrinsic height.
    @ViewBuilder
    private func splitDivider(available: CGFloat, draggable: Bool) -> some View {
        let base = Rectangle()
            .fill(Color.clear)
            .frame(height: dividerThickness)
            .overlay(
                Rectangle()
                    .fill(.separator.opacity(0.6))
                    .frame(height: 1)
            )
        if draggable {
            base
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartFraction == nil { dragStartFraction = chatFraction }
                            guard let start = dragStartFraction else { return }
                            let delta = value.translation.height / available
                            chatFraction = clampFraction(start + delta, available: available)
                        }
                        .onEnded { _ in
                            dragStartFraction = nil
                        }
                )
                .help("Drag to resize the AI / transcript split")
        } else {
            base
        }
    }

    /// Keep each pane at least `minPaneHeight` tall. If the window is too short to
    /// honor that for both panes, fall back to a 50/50 split — the content will
    /// scroll inside whichever pane runs short.
    private func clampFraction(_ raw: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 2 * minPaneHeight else { return 0.5 }
        let minF = minPaneHeight / available
        let maxF = 1 - minF
        return max(minF, min(maxF, raw))
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
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            HStack(alignment: .bottom, spacing: WP.Space.sm) {
                TextField("Ask the AI — uses live transcript and chat history as context", text: $state.composerText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(WP.TextStyle.body)
                    .focused($composerFocused)
                    .onSubmit { submit() }
                    .padding(.horizontal, WP.Space.sm + 2)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                            .fill(.quinary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                            .strokeBorder(composerFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 0.75)
                    )

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isComposerEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isComposerEmpty)
                .help("Send to AI (⌘⏎)")
            }

            HStack(spacing: WP.Space.sm) {
                Button(action: { includeScreenshot.toggle() }) {
                    HStack(spacing: WP.Space.xs) {
                        Image(systemName: includeScreenshot ? "eye.fill" : "eye")
                            .font(.system(size: 10))
                        Text("See my screen")
                            .font(WP.TextStyle.micro)
                        if includeScreenshot {
                            Text("· attached")
                                .font(WP.TextStyle.tag)
                        }
                    }
                    .chip(includeScreenshot ? .accent : .neutral)
                }
                .buttonStyle(.plain)
                .help("When on, the AI receives a screenshot of your current display along with this message.")

                // Manual fallback when the question detector misses a question — the AI
                // gets the same full context but is told to *find* the unanswered question
                // itself, then answer it. Green to read as "go / help me now" against the
                // accent-blue submit affordance.
                Button(action: { actions.requestHelpAI() }) {
                    HStack(spacing: WP.Space.xs) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Help AI")
                            .font(WP.TextStyle.micro)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.green.opacity(0.18))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.green.opacity(0.45), lineWidth: 0.75)
                    )
                    .foregroundStyle(Color.green)
                }
                .buttonStyle(.plain)
                .help("Ask the AI to find any unanswered question in the recent transcript and answer it, using full context.")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, WP.Space.md)
        .padding(.vertical, WP.Space.sm + 2)
    }

    private var isComposerEmpty: Bool {
        state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        HStack(alignment: .top, spacing: WP.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: WP.Space.sm - 2) {
                Text(spec.message)
                    .font(WP.TextStyle.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let button = spec.button {
                    Button(button.title, action: button.action)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(WP.Space.md - 2)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct ChannelMuteButton: View {
    let isMuted: Bool
    let activeIcon: String
    let mutedIcon: String
    let activeHelp: String
    let mutedHelp: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? mutedIcon : activeIcon)
                .font(.system(size: 13))
                .foregroundStyle(isMuted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? mutedHelp : activeHelp)
    }
}

private struct StatusDot: View {
    let status: OverlayStatus
    @State private var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(shouldPulse ? (pulsing ? 0.35 : 1.0) : 1.0)
            .onAppear { restartPulse() }
            .onChange(of: shouldPulse) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        // Two-stage animation: snap pulsing back to false then animate to true with
        // repeatForever-autoreverse so the dot actually oscillates. Without the snap,
        // SwiftUI sees no value change and the animation never starts.
        pulsing = false
        if shouldPulse {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private var color: Color {
        switch status {
        case .idle: return .gray
        case .starting: return .blue
        case .listening: return .green
        case .thinking: return .yellow
        case .streaming: return .blue
        case .needsPermission, .needsAPIKey: return .orange
        case .error: return .red
        }
    }

    private var shouldPulse: Bool {
        switch status {
        case .starting, .listening, .thinking, .streaming: return true
        default: return false
        }
    }
}

private struct ChatLane: View {
    let messages: [ChatMessage]
    let isAIPaused: Bool
    let onToggleAI: () -> Void
    let onDismissMessage: (UUID) -> Void
    /// Two-way binding to the session's user-supplied context (notes + attached
    /// files). Edits flow through `OverlayState.sessionContext`; the coordinator
    /// debounces saves to disk.
    @Binding var sessionContext: SessionContext
    /// When true, only the header is rendered. Owner manages the state and
    /// passes a toggle closure so the lane can fire when its chevron is tapped.
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("AI")
                    .font(WP.TextStyle.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                AIToggleButton(isPaused: isAIPaused, action: onToggleAI)
                if let onToggleCollapse {
                    CollapseChevron(isCollapsed: isCollapsed, action: onToggleCollapse)
                        .help(isCollapsed ? "Show AI conversation" : "Hide AI conversation")
                }
            }

            if !isCollapsed {
                ContextDropdown(context: $sessionContext)

                if messages.isEmpty {
                    EmptyStatePill(
                        icon: isAIPaused ? "pause.circle" : "sparkles",
                        text: emptyStateText
                    )
                } else {
                    ForEach(messages) { message in
                        MessageBubble(message: message, onDismiss: { onDismissMessage(message.id) })
                            .id(message.id)
                    }
                }
            }
        }
    }

    private var emptyStateText: String {
        if isAIPaused {
            return "AI is paused — manual prompts still go through."
        }
        return "Detected questions and AI suggestions appear here."
    }
}

private struct EmptyStatePill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: WP.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(WP.TextStyle.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WP.Space.md - 2)
        .padding(.vertical, WP.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(.quinary)
        )
    }
}

private struct AIToggleButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: WP.Space.xs + 1) {
                Image(systemName: isPaused ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(isPaused ? "Paused" : "Active")
                    .font(WP.TextStyle.tag)
            }
            .chip(isPaused ? .warning : .success)
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
        VStack(alignment: .leading, spacing: WP.Space.xs + 2) {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: roleIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(roleColor)
                Text(roleLabel)
                    .font(WP.TextStyle.tag)
                    .foregroundStyle(roleColor)
                if let originBadge {
                    Text(originBadge)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if message.isStreaming {
                    TypingIndicator()
                }
                Spacer(minLength: 0)
                // System notes are informational — the user should be able to clear them
                // when they've read them. Other roles persist (chat history is meaningful).
                if message.role == .system, let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            Text(renderedText)
                .font(WP.TextStyle.body)
                .foregroundStyle(message.role == .system ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(.accentColor)
        }
        .padding(WP.Space.md - 2)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(bubbleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .strokeBorder(bubbleStroke, lineWidth: 0.5)
        )
    }

    /// Renders the body text. Assistant messages parse as inline markdown — bold,
    /// italic, links, inline code — so Gemini's typical `**word**` and backticks come
    /// through styled rather than as raw characters. `.inlineOnlyPreservingWhitespace`
    /// is deliberate: block-level constructs (headings, lists, code fences) don't render
    /// reliably inside a single `Text`, and mid-stream partials would look broken if we
    /// tried. User messages and system notes stay plain so we never re-interpret what
    /// the user actually typed.
    private var renderedText: AttributedString {
        let raw = message.text
        if raw.isEmpty { return AttributedString("…") }
        guard message.role == .assistant else { return AttributedString(raw) }
        let parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return parsed ?? AttributedString(raw)
    }

    /// User-role messages double as auto-trigger preambles when their origin is
    /// `.detectedQuestion` or `.helpAI`. Those preambles need their own icon /
    /// label / color so the user can tell at a glance which subsystem fired the
    /// AI call, instead of seeing every chat row labeled "You".
    private var isAutoDetectedQuestion: Bool {
        message.role == .user && message.origin == .detectedQuestion
    }

    private var isHelpAIPreamble: Bool {
        message.role == .user && message.origin == .helpAI
    }

    private var roleIcon: String {
        if isAutoDetectedQuestion { return "questionmark.bubble.fill" }
        if isHelpAIPreamble       { return "sparkles" }
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .system: return "info.circle.fill"
        }
    }

    private var roleLabel: String {
        if isAutoDetectedQuestion { return "Auto-detected question" }
        if isHelpAIPreamble       { return "Help AI" }
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    private var roleColor: Color {
        if isAutoDetectedQuestion { return .orange }
        if isHelpAIPreamble       { return .green }
        switch message.role {
        case .user: return .purple
        case .assistant: return .blue
        case .system: return .secondary
        }
    }

    /// Suppress the trailing origin badge on the preamble bubbles — the role label
    /// itself already says "Auto-detected question" / "Help AI", so a redundant tag
    /// would just be visual noise. We still show it on the assistant's reply so the
    /// user can correlate reply ↔ trigger.
    private var originBadge: String? {
        if isAutoDetectedQuestion || isHelpAIPreamble { return nil }
        switch message.origin {
        case .detectedQuestion: return "· detected question"
        case .helpAI: return "· help AI"
        case .userPrompt, .system: return nil
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        if isAutoDetectedQuestion { return AnyShapeStyle(Color.orange.opacity(0.08)) }
        if isHelpAIPreamble       { return AnyShapeStyle(Color.green.opacity(0.10)) }
        switch message.role {
        case .user: return AnyShapeStyle(Color.purple.opacity(0.08))
        case .assistant: return AnyShapeStyle(Color.blue.opacity(0.07))
        case .system: return AnyShapeStyle(.quinary)
        }
    }

    private var bubbleStroke: Color {
        if isAutoDetectedQuestion { return Color.orange.opacity(0.20) }
        if isHelpAIPreamble       { return Color.green.opacity(0.25) }
        switch message.role {
        case .user: return Color.purple.opacity(0.18)
        case .assistant: return Color.blue.opacity(0.18)
        case .system: return Color.primary.opacity(0.08)
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
