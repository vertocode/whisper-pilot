import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaved: Bool = false
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                BrandLogo()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper Pilot")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Ambient AI for live conversations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            TabView {
                generalTab.tabItem { Label("General", systemImage: "gearshape") }
                devicesTab.tabItem { Label("Devices", systemImage: "mic.and.signal.meter") }
                providerTab.tabItem { Label("AI Provider", systemImage: "brain") }
                captureTab.tabItem { Label("Capture", systemImage: "waveform") }
                overlayTab.tabItem { Label("Overlay", systemImage: "rectangle.on.rectangle") }
            }
        }
        .frame(width: 540, height: 460)
        .padding()
        .onAppear {
            apiKeyDraft = store.geminiAPIKey ?? ""
            apiKeySaved = !apiKeyDraft.isEmpty
            inputDevices = MicrophoneCapture.listInputDevices()
        }
    }

    private var devicesTab: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: $store.microphoneDeviceUID) {
                    Text("System default").tag(nil as String?)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                Button("Refresh device list") {
                    inputDevices = MicrophoneCapture.listInputDevices()
                }
                .controlSize(.small)
            }

            Section {
                Text("The microphone selection takes effect the next time you click ▶ Play. \"System default\" follows your current System Settings → Sound → Input choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("System audio") {
                if let info = MicrophoneCapture.defaultOutputDeviceInfo() {
                    LabeledContent("Active output", value: info.name ?? "unknown (id=\(info.id))")
                } else {
                    LabeledContent("Active output", value: "unknown")
                }
                Text("System audio is captured via the macOS audio mixdown for whatever your default output device is. Change it in System Settings → Sound → Output. Some Bluetooth codecs and virtual / aggregate devices bypass the mixdown — if Audio Test reports silence, switch to built-in speakers or wired output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Picker("Response style", selection: $store.responseStyle) {
                ForEach(ResponseStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Text(store.responseStyle.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Locale", selection: $store.localeIdentifier) {
                ForEach(Self.locales, id: \.self) { id in
                    Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                }
            }

            Picker("Auto-send to AI", selection: $store.autoSendInterval) {
                ForEach(AutoSendInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            Text("When AI is active and this is on, the assistant proactively summarizes the recent conversation at the chosen interval. Question detection still fires independently.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Transcript line break", selection: $store.utteranceBoundary) {
                ForEach(UtteranceBoundary.allCases, id: \.self) { boundary in
                    Text(boundary.displayName).tag(boundary)
                }
            }
            Text(store.utteranceBoundary.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var providerTab: some View {
        Form {
            Section("Gemini") {
                SecureField("API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(apiKeySaved ? "Update key" : "Save key") {
                        store.geminiAPIKey = apiKeyDraft
                        apiKeySaved = !apiKeyDraft.isEmpty
                    }
                    .disabled(apiKeyDraft.isEmpty)

                    if apiKeySaved {
                        Button("Remove") {
                            store.geminiAPIKey = nil
                            apiKeyDraft = ""
                            apiKeySaved = false
                        }
                    }

                    Spacer()

                    Link("Get a key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.callout)
                }

                Picker("Model", selection: $store.geminiModel) {
                    Text("gemini-2.0-flash").tag("gemini-2.0-flash")
                    Text("gemini-2.0-flash-lite").tag("gemini-2.0-flash-lite")
                    Text("gemini-2.5-flash").tag("gemini-2.5-flash")
                    Text("gemini-2.5-pro").tag("gemini-2.5-pro")
                }

                Text("Stored in the macOS Keychain. Never written to disk in plaintext.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var captureTab: some View {
        Form {
            Toggle("Capture microphone", isOn: $store.captureMicrophone)
            Text("System audio (everything macOS plays — Teams, Meet, Slack, browser) is always captured. Microphone is optional and lets the assistant attribute who said what.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var overlayTab: some View {
        Form {
            Toggle("Always on top", isOn: $store.alwaysOnTop)
            Toggle("Click-through", isOn: $store.clickThrough)
            Text("Click-through ignores mouse events on the overlay so it never intercepts clicks meant for your meeting window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private static let locales: [String] = [
        "en-US", "en-GB", "pt-BR", "pt-PT", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "nl-NL", "ja-JP"
    ]
}
