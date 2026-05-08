import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var apiKeyDraft: String = ""
    @State private var apiKeySaved: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image("WhisperPilotLogo")
                    .resizable()
                    .scaledToFit()
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
                providerTab.tabItem { Label("AI Provider", systemImage: "brain") }
                captureTab.tabItem { Label("Capture", systemImage: "waveform") }
                overlayTab.tabItem { Label("Overlay", systemImage: "rectangle.on.rectangle") }
            }
        }
        .frame(width: 520, height: 420)
        .padding()
        .onAppear {
            apiKeyDraft = store.geminiAPIKey ?? ""
            apiKeySaved = !apiKeyDraft.isEmpty
        }
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
