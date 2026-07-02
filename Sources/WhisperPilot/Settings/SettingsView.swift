import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var geminiAPIKeyDraft: String = ""
    @State private var geminiAPIKeySaved: Bool = false
    @State private var anthropicAPIKeyDraft: String = ""
    @State private var anthropicAPIKeySaved: Bool = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var screens: [ScreenInfo] = []

    var body: some View {
        VStack(spacing: WP.Space.md) {
            header
            TabView {
                generalTab.tabItem { Label("General", systemImage: "gearshape") }
                devicesTab.tabItem { Label("Devices", systemImage: "mic.and.signal.meter") }
                aiBehaviorTab.tabItem { Label("AI Behavior", systemImage: "sparkles") }
                providerTab.tabItem { Label("AI Provider", systemImage: "brain") }
                captureTab.tabItem { Label("Capture", systemImage: "waveform") }
                overlayTab.tabItem { Label("Overlay", systemImage: "rectangle.on.rectangle") }
                shortcutsTab.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }
        }
        // Sized so all six tabs fit on a single row — narrower windows collapse the
        // trailing tabs behind a `>>` overflow chevron, which hides the AI Provider /
        // Capture / Overlay panes behind an extra click.
        .frame(minWidth: 820, idealWidth: 880, minHeight: 480, idealHeight: 520)
        .padding(WP.Space.md)
        .onAppear {
            geminiAPIKeyDraft = store.geminiAPIKey ?? ""
            geminiAPIKeySaved = !geminiAPIKeyDraft.isEmpty
            anthropicAPIKeyDraft = store.anthropicAPIKey ?? ""
            anthropicAPIKeySaved = !anthropicAPIKeyDraft.isEmpty
            inputDevices = MicrophoneCapture.listInputDevices()
            screens = ScreenEnumerator.connectedScreens()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: WP.Space.md) {
            BrandLogo()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.brandLabel)
                    .font(.system(size: 15, weight: .semibold))
                Text("Ambient AI for live conversations")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Renders only when a newer GitHub release exists. Settings is
            // where users go to poke at the app, so it's a natural surface
            // for the upgrade nudge.
            UpdateAvailableButton()
            // Shown across every Settings tab — one place a user already opens
            // when they're looking up where things live, so it's a natural
            // spot to put the optional "say thanks" affordance.
            SupportLink(style: .expanded)
        }
        .padding(.horizontal, WP.Space.xs)
        .padding(.bottom, WP.Space.xs)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Response style", selection: $store.responseStyle) {
                    ForEach(ResponseStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                FormHint(store.responseStyle.description)
            }

            Section {
                Picker("Locale", selection: $store.localeIdentifier) {
                    ForEach(Self.locales, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
                FormHint("Used by the speech recognizer. Match the language of the audio you're transcribing.")
            }

            Section("Performance safety valve") {
                Toggle("Enable safety valve", isOn: $store.safetyValveEnabled)
                FormHint("Watches this app's own CPU, memory, and thermal state while listening and backs off before your Mac freezes: a soft pause of AI auto-suggestions first, then a full stop if load stays high. Turn off to revert to the old no-limit behavior. Live numbers appear in the overlay's Diagnostics panel.")
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("CPU threshold")
                        Spacer()
                        Text("\(Int(store.safetyValveCPUPercent.rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.safetyValveCPUPercent, in: 40...95, step: 5)
                }
                .disabled(!store.safetyValveEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Memory threshold")
                        Spacer()
                        Text("\(store.safetyValveMemoryMB) MB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(store.safetyValveMemoryMB) },
                            set: { store.safetyValveMemoryMB = Int($0) }
                        ),
                        in: 500...4000,
                        step: 100
                    )
                }
                .disabled(!store.safetyValveEnabled)
                FormHint("The soft pause (Tier-1) trips when this app's own CPU stays above the threshold for ~20s, or its memory crosses the cap. Thermal pressure and sustained overload escalate to a full stop. Tune these to your Mac; threshold changes apply the next time you start listening.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - AI Behavior

    /// Per-feature AI toggles. All default to true so the assistant works out of
    /// the box; flipping any of them off shrinks the prompt or skips a side
    /// effect, trading capability for tokens / cost / latency.
    private var aiBehaviorTab: some View {
        Form {
            Section("Automatic AI calls") {
                Toggle("Auto-answer questions from Other", isOn: $store.autoDetectQuestionsFromOther)
                FormHint("When on, questions captured on the system-audio side (the other speaker in a meeting) automatically fire an AI call.")
                Toggle("Auto-answer questions from Me", isOn: $store.autoDetectQuestionsFromMe)
                FormHint("When on, questions captured on your microphone also fire an AI call. Off by default because the spoken version often duplicates what you'd type to the assistant directly.")
            }

            Section("Prompt context") {
                Toggle("Include live transcript", isOn: $store.includeTranscriptInPrompt)
                FormHint("Sends the recent conversation lines (and any resumed prior transcript) to the model on every call. Cheapest setting to flip if your transcript is long but the AI doesn't need it for what you're asking.")
                Toggle("Include system audio (\"Other\") in AI context", isOn: $store.includeSystemAudioInPrompt)
                FormHint("Excludes what \"Other\" said from the AI's view. The transcript pane still shows it — only the model loses access. Useful when only your side of the call should be summarized.")
                Toggle("Include prior AI chat history", isOn: $store.includeChatHistoryInPrompt)
                FormHint("Sends recent assistant/user turns so the model can resolve \"translate that\" / \"explain more\" follow-ups. Turn off for single-shot answers — saves the most tokens but breaks multi-turn reference.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Devices

    private var devicesTab: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: $store.microphoneDeviceUID) {
                    Text("System default").tag(nil as String?)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh device list") {
                        inputDevices = MicrophoneCapture.listInputDevices()
                    }
                    .controlSize(.small)
                }
                FormHint("Microphone selection takes effect the next time you click Play. \"System default\" follows your current System Settings → Sound → Input choice.")
            }

            Section("System audio") {
                if let info = MicrophoneCapture.defaultOutputDeviceInfo() {
                    LabeledContent("Active output", value: info.name ?? "unknown (id=\(info.id))")
                } else {
                    LabeledContent("Active output", value: "unknown")
                }
                FormHint("System audio is captured via the macOS audio mixdown for whatever your default output device is. Change it in System Settings → Sound → Output. Some Bluetooth codecs and virtual / aggregate devices bypass the mixdown — if Audio Test reports silence, switch to built-in speakers or wired output.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - AI Provider

    private var providerTab: some View {
        Form {
            Section("Active model") {
                modelPicker
                if let warning = activeModelKeyWarning {
                    HStack(alignment: .top, spacing: WP.Space.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                FormHint("Shows every model whose vendor has an API key configured below. Per-session model selection lives in the overlay — this picker controls the default for new sessions.")
            }

            Section("Gemini") {
                apiKeySection(
                    draft: $geminiAPIKeyDraft,
                    saved: $geminiAPIKeySaved,
                    vendorDocsURL: "https://aistudio.google.com/app/apikey",
                    onSave: { store.geminiAPIKey = geminiAPIKeyDraft },
                    onRemove: { store.geminiAPIKey = nil }
                )
                FormHint("`gemini-2.0-flash` was retired for new Google AI Studio keys. If the selected model returns a 404, Whisper Pilot auto-switches to a working one and retries.")
            }

            Section("Claude (Anthropic)") {
                apiKeySection(
                    draft: $anthropicAPIKeyDraft,
                    saved: $anthropicAPIKeySaved,
                    vendorDocsURL: "https://console.anthropic.com/settings/keys",
                    onSave: { store.anthropicAPIKey = anthropicAPIKeyDraft },
                    onRemove: { store.anthropicAPIKey = nil }
                )
                FormHint("Use a Claude API key from console.anthropic.com. The Claude models above only appear in the Active model picker when this key is set.")
            }

            Section {
                HStack(spacing: WP.Space.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("API keys are stored in the macOS Keychain. Never written to disk in plaintext.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Unified model picker. Groups models by vendor and disables rows whose
    /// vendor has no key configured — the user sees what's available without
    /// having to remember which section the model lives in. Mutates
    /// `store.activeModel` directly so the coordinator picks up the change
    /// via its existing key-watching path.
    @ViewBuilder
    private var modelPicker: some View {
        let vendors = store.availableVendors
        Picker("Model", selection: $store.activeModel) {
            ForEach(AIVendor.allCases, id: \.self) { vendor in
                let isAvailable = vendors.contains(vendor)
                ForEach(AIModelRegistry.models(for: vendor)) { model in
                    Text(rowLabel(for: model, vendorAvailable: isAvailable))
                        .tag(model.id)
                }
            }
        }
    }

    /// Inline warning under the model picker when the active model's vendor
    /// doesn't have a key set. Picker (unlike Menu) can't disable individual
    /// rows, so this is the only place users see that the current selection
    /// is non-functional until they add a key. Nil = the active model can run.
    private var activeModelKeyWarning: String? {
        guard let model = AIModelRegistry.model(for: store.activeModel) else { return nil }
        if store.availableVendors.contains(model.vendor) { return nil }
        return "The active model needs a \(model.vendor.displayName) API key — add one in the section below, or pick a different model."
    }

    private func rowLabel(for model: AIModel, vendorAvailable: Bool) -> String {
        let suffix = vendorAvailable ? "" : "  ⚠ no \(model.vendor.displayName) API key"
        if let tagline = model.tagline {
            return "\(model.displayName) — \(tagline)\(suffix)"
        }
        return "\(model.displayName)\(suffix)"
    }

    /// Reusable save / update / remove row used by both vendor sections.
    /// Kept inline (rather than a `View` struct) so the per-vendor `@Binding`s
    /// to `apiKeyDraft` / `apiKeySaved` stay tied to this view's `@State`.
    @ViewBuilder
    private func apiKeySection(
        draft: Binding<String>,
        saved: Binding<Bool>,
        vendorDocsURL: String,
        onSave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        SecureField("API key", text: draft)
            .textFieldStyle(.roundedBorder)
        HStack(spacing: WP.Space.sm) {
            Button(saved.wrappedValue ? "Update key" : "Save key") {
                onSave()
                saved.wrappedValue = !draft.wrappedValue.isEmpty
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(draft.wrappedValue.isEmpty)

            if saved.wrappedValue {
                Button("Remove") {
                    onRemove()
                    draft.wrappedValue = ""
                    saved.wrappedValue = false
                }
            }

            Spacer()

            Link(destination: URL(string: vendorDocsURL)!) {
                HStack(spacing: 4) {
                    Text("Get a key")
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - Capture

    private var captureTab: some View {
        Form {
            Section {
                Toggle("Capture microphone", isOn: $store.captureMicrophone)
                FormHint("System audio (everything macOS plays — Teams, Meet, Slack, browser) is always captured. Microphone is optional and lets the assistant attribute who said what.")
                Toggle("Always transcribe my mic", isOn: $store.alwaysTranscribeMic)
                    .disabled(!store.captureMicrophone)
                FormHint("When off, a new session starts with your mic muted — system audio (\"Other\") still transcribes, but your own voice is skipped until you unmute with the in-session mic toggle. Useful if you rarely need your own speech transcribed and want to avoid the mic recognizer's cost. Has no effect when microphone capture above is off.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Overlay

    /// Selecting a mode goes through `applyOverlayLayoutMode` so the individual
    /// appearance settings get filled from the preset — a plain assignment would
    /// just relabel the mode without changing anything.
    private var overlayModeBinding: Binding<OverlayLayoutMode> {
        Binding(
            get: { store.overlayLayoutMode },
            set: { store.applyOverlayLayoutMode($0) }
        )
    }

    private var overlayTab: some View {
        Form {
            Section("Layout mode") {
                Picker("Mode", selection: overlayModeBinding) {
                    ForEach(OverlayLayoutMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                    }
                }
                FormHint(store.overlayLayoutMode.summary)
            }

            Section("Size & position") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Width")
                        Spacer()
                        Text("\(Int((store.overlayWidthFraction * 100).rounded()))% of screen")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.overlayWidthFraction, in: 0.25...1.0, step: 0.01)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Height")
                        Spacer()
                        Text("\(Int((store.overlayHeightFraction * 100).rounded()))% of screen")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.overlayHeightFraction, in: 0.25...1.0, step: 0.01)
                }
                Picker("Anchor position", selection: $store.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
                FormHint("Size is a fraction of your screen's usable area; the window anchors to the chosen edge or corner. Dragging or resizing the overlay yourself switches the mode to Custom.")
            }

            Section("Appearance") {
                Toggle("Show live transcript pane", isOn: $store.overlayShowTranscript)
                Toggle("Show Summary & Action buttons", isOn: $store.overlayShowExtraActions)
                Toggle("Compact chrome (denser, smaller)", isOn: $store.overlayCompactChrome)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Background opacity")
                        Spacer()
                        Text("\(Int((store.overlayBackgroundOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.overlayBackgroundOpacity, in: 0.4...1.0, step: 0.01)
                }
                Picker("Text color", selection: $store.overlayTextColorHex) {
                    ForEach(OverlayColor.palette, id: \.hex) { item in
                        Text(item.name).tag(item.hex)
                    }
                }
                FormHint("Lower opacity makes the panel more see-through; text and buttons stay fully opaque. Help AI and the screenshot/send controls always remain regardless of the buttons toggle.")
            }

            Section {
                Toggle("Always on top", isOn: $store.alwaysOnTop)
                FormHint("Keeps the overlay floating above your meeting window so you can read suggestions without alt-tabbing.")
            }
            Section {
                Toggle("Click-through", isOn: $store.clickThrough)
                FormHint("Click-through ignores mouse events on the overlay so it never intercepts clicks meant for your meeting window.")
            }
            Section {
                Toggle("Hide from screen sharing", isOn: $store.hideFromScreenSharing)
                FormHint("Excludes the overlay from screen-capture APIs (WebRTC, ScreenCaptureKit, QuickTime, macOS screenshots). The window stays visible on your local display, but other meeting participants and recordings won't see it.")
            }
            Section("Screen capture") {
                Picker("Monitor", selection: $store.screenCaptureDisplayID) {
                    Text("Monitor with the pointer (follow)").tag(UInt32(0))
                    ForEach(screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh monitors") {
                        screens = ScreenEnumerator.connectedScreens()
                    }
                    .controlSize(.small)
                }
                FormHint("Which monitor \"See my screen\" and the answer-screen shortcut (⌘⇧A) capture. \"Follow\" uses whichever monitor your pointer is on. Pick a specific monitor to always capture that one, even while you're looking at another. If a pinned monitor is disconnected, capture falls back to an available display.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        Form {
            Section {
                HStack {
                    Text("Show/hide overlay")
                    Spacer()
                    KeyRecorderField(shortcut: $store.toggleOverlayShortcut)
                        .frame(width: 140, height: 26)
                    Button("Reset") {
                        store.toggleOverlayShortcut = .toggleOverlayDefault
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                FormHint("Global shortcut — works from any app, including when the overlay is click-through. Click the field, then press the combo you want. Press Escape to cancel without changing. Default: ⌘⇧Z.")
            }
            Section {
                HStack {
                    Text("Answer what's on screen")
                    Spacer()
                    KeyRecorderField(shortcut: $store.answerScreenShortcut)
                        .frame(width: 140, height: 26)
                    Button("Reset") {
                        store.answerScreenShortcut = .answerScreenDefault
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                FormHint("Captures your current screen and asks the AI to answer whatever question is visible — picks the right option for multiple-choice, or replies briefly for an open question. If there's no question, it tells you what it sees and offers to help. Requires Screen Recording permission. Default: ⌘⇧A.")
            }
        }
        .formStyle(.grouped)
    }

    private static let locales: [String] = [
        "en-US", "en-GB", "pt-BR", "pt-PT", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "nl-NL", "ja-JP"
    ]
}

/// Inline helper text used under controls in Settings tabs. One source of truth so every
/// hint has matching size/color/wrapping behavior.
private struct FormHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
