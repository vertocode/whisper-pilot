import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaved: Bool = false
    @State private var inputDevices: [AudioInputDevice] = []

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
            }
        }
        // Sized so all six tabs fit on a single row — narrower windows collapse the
        // trailing tabs behind a `>>` overflow chevron, which hides the AI Provider /
        // Capture / Overlay panes behind an extra click.
        .frame(minWidth: 820, idealWidth: 880, minHeight: 480, idealHeight: 520)
        .padding(WP.Space.md)
        .onAppear {
            apiKeyDraft = store.geminiAPIKey ?? ""
            apiKeySaved = !apiKeyDraft.isEmpty
            inputDevices = MicrophoneCapture.listInputDevices()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: WP.Space.md) {
            BrandLogo()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whisper Pilot")
                    .font(.system(size: 15, weight: .semibold))
                Text("Ambient AI for live conversations")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

            Section {
                Picker("Transcript line break", selection: $store.utteranceBoundary) {
                    ForEach(UtteranceBoundary.allCases, id: \.self) { boundary in
                        Text(boundary.displayName).tag(boundary)
                    }
                }
                FormHint(store.utteranceBoundary.description)
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
                Toggle("Auto-answer detected questions", isOn: $store.autoDetectQuestionsEnabled)
                FormHint("When on, sentences in the transcript that look like questions automatically fire an AI call. Turn off to stop the model from chiming in on its own; you can still send manually or use the Help AI button.")
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
            Section("Gemini") {
                SecureField("API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: WP.Space.sm) {
                    Button(apiKeySaved ? "Update key" : "Save key") {
                        store.geminiAPIKey = apiKeyDraft
                        apiKeySaved = !apiKeyDraft.isEmpty
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(apiKeyDraft.isEmpty)

                    if apiKeySaved {
                        Button("Remove") {
                            store.geminiAPIKey = nil
                            apiKeyDraft = ""
                            apiKeySaved = false
                        }
                    }

                    Spacer()

                    Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                        HStack(spacing: 4) {
                            Text("Get a key")
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 12))
                    }
                }

                Picker("Model", selection: $store.geminiModel) {
                    Text("gemini-2.5-flash").tag("gemini-2.5-flash")
                    Text("gemini-2.0-flash-lite").tag("gemini-2.0-flash-lite")
                    Text("gemini-2.5-pro").tag("gemini-2.5-pro")
                    Text("gemini-2.0-flash (legacy)").tag("gemini-2.0-flash")
                }
                FormHint("If the selected model returns a 404, Whisper Pilot will auto-switch to a working one and retry. `gemini-2.0-flash` was retired for new Google AI Studio keys — pick `gemini-2.5-flash` unless you specifically need a different model.")

                HStack(spacing: WP.Space.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Stored in the macOS Keychain. Never written to disk in plaintext.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Capture

    private var captureTab: some View {
        Form {
            Section {
                Toggle("Capture microphone", isOn: $store.captureMicrophone)
                FormHint("System audio (everything macOS plays — Teams, Meet, Slack, browser) is always captured. Microphone is optional and lets the assistant attribute who said what.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Overlay

    private var overlayTab: some View {
        Form {
            Section {
                Toggle("Always on top", isOn: $store.alwaysOnTop)
                FormHint("Keeps the overlay floating above your meeting window so you can read suggestions without alt-tabbing.")
            }
            Section {
                Toggle("Click-through", isOn: $store.clickThrough)
                FormHint("Click-through ignores mouse events on the overlay so it never intercepts clicks meant for your meeting window.")
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
