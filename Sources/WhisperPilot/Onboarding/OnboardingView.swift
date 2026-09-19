import AppKit
import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable, Hashable {
        case welcome
        case permissions
        case ai

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Access"
            case .ai: return "Answer"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: return "waveform"
            case .permissions: return "checkmark.shield.fill"
            case .ai: return "sparkles"
            }
        }
    }

    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var settings: SettingsStore
    let onFinish: () -> Void
    /// macOS dialogs take focus from the app, which leaves this window behind
    /// other windows. Called after each request to put it back in front.
    let bringToFront: () -> Void

    @State private var step: Step
    @State private var selectedVendor: AIVendor = .gemini
    @State private var apiKey = ""
    /// The item whose macOS dialog is on screen right now. Keeps a second click
    /// from stacking another request behind the first.
    @State private var requesting: SetupItem?
    @FocusState private var apiKeyFocused: Bool

    /// `start` skips screens the user already saw, for example when the window is
    /// reopened from Settings or the overlay, where they already know the app.
    init(
        permissions: PermissionsManager,
        settings: SettingsStore,
        start: OnboardingStart = .welcome,
        bringToFront: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.settings = settings
        self.bringToFront = bringToFront
        self.onFinish = onFinish
        switch start {
        case .welcome: _step = State(initialValue: .welcome)
        case .permissions: _step = State(initialValue: .permissions)
        case .ai: _step = State(initialValue: .ai)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            signalRail
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)
            content
        }
        .frame(width: 780, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { Task { await permissions.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private var signalRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLogo()
                .frame(width: 54, height: 54)

            Text("Whisper Pilot")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, WP.Space.md)
            Text("Hear the conversation.\nKeep your attention in it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.top, WP.Space.xs)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Step.allCases.enumerated()), id: \.element) { index, item in
                    railStep(item)
                    if index < Step.allCases.count - 1 {
                        Rectangle()
                            .fill(item.rawValue < step.rawValue ? Color.accentColor : Color.secondary.opacity(0.22))
                            .frame(width: 1, height: 34)
                            .padding(.leading, 15.5)
                    }
                }
            }
            .padding(.top, 46)

            Spacer()

            Label("Audio stays on this Mac", systemImage: "lock.shield.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(width: 244, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.11), Color.purple.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func railStep(_ item: Step) -> some View {
        HStack(spacing: WP.Space.md) {
            ZStack {
                Circle()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: item.rawValue < step.rawValue ? "checkmark" : item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.rawValue <= step.rawValue ? Color.white : Color.secondary)
            }
            Text(item.title)
                .font(.system(size: 13, weight: item == step ? .semibold : .regular))
                .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .permissions:
            permissionsStep
        case .ai:
            aiStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Image(systemName: "waveform.and.mic")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, WP.Space.xl)

            Text("Stay present. Whisper Pilot listens locally.")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)

            Text("Live speech becomes a private transcript on your Mac. When you want help, your chosen AI turns conversation context into a useful answer.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 450, alignment: .leading)
                .padding(.top, WP.Space.md)

            HStack(spacing: 22) {
                compactFact("On-device", symbol: "laptopcomputer")
                compactFact("No meeting bot", symbol: "person.slash")
                compactFact("Your API key", symbol: "key.fill")
            }
            .padding(.top, 30)

            Spacer()
            footer(primaryTitle: "Continue", primaryAction: { step = .permissions })
        }
        .contentPadding()
    }

    private func compactFact(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    // MARK: - Permissions

    private var requiresScreenRecording: Bool {
        settings.forceScreenCaptureKitForSystemAudio || !PermissionsManager.processTapSupported
    }

    private var missingRequired: [SetupItem] {
        OnboardingEligibility.missing(
            captureMicrophone: settings.captureMicrophone,
            requiresScreenRecording: requiresScreenRecording,
            processTapSupported: PermissionsManager.processTapSupported,
            permissions: permissions.snapshot,
            keychain: settings.keychainAccess
        )
    }

    private var visibleItems: [SetupItem] {
        var items: [SetupItem] = []
        if settings.captureMicrophone { items.append(.microphone) }
        items.append(.speechRecognition)
        if !requiresScreenRecording { items.append(.systemAudio) }
        items.append(.screenRecording)
        items.append(.keychain)
        return items
    }

    private func title(of item: SetupItem) -> String {
        switch item {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .systemAudio: return "System audio"
        case .screenRecording: return "Screen Recording"
        case .keychain: return "Keychain"
        }
    }

    private func symbol(of item: SetupItem) -> String {
        switch item {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "text.bubble.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .keychain: return "key.fill"
        }
    }

    private func reason(of item: SetupItem) -> String {
        switch item {
        case .microphone:
            return "Adds your own voice to the transcript, so answers know who said what. Audio is processed on this Mac."
        case .speechRecognition:
            return "Apple's speech engine turns audio into text on this Mac. Used for languages other than English, and as a backup for English."
        case .systemAudio:
            return "Hears the other side of the call (Zoom, Meet, Teams, a browser). Audio only. Nothing is recorded to disk, only the text transcript."
        case .screenRecording:
            return requiresScreenRecording
                ? "Needed to hear system audio on this Mac. Audio only. No video is saved."
                : "Only used when you press Answer screen, so the AI can read what is on your display. Also the backup way to hear system audio. No video is saved."
        case .keychain:
            let names = storedVendorNames
            if names.isEmpty {
                return "Your API keys are kept in the macOS Keychain, Apple's secure vault, and read only to call your AI provider. You have not saved one yet, so there is nothing to unlock."
            }
            return "Your \(names) API key is saved in the macOS Keychain. Whisper Pilot reads it to send your requests to the AI provider. Choose “Always Allow”."
        }
    }

    private var storedVendorNames: String {
        AIVendor.allCases
            .filter { settings.availableVendors.contains($0) }
            .map(\.displayName)
            .joined(separator: " and ")
    }

    private func status(of item: SetupItem) -> PermissionStatus {
        switch item {
        case .microphone: return permissions.snapshot.microphone
        case .speechRecognition: return permissions.snapshot.speechRecognition
        case .systemAudio: return permissions.snapshot.systemAudio
        case .screenRecording: return permissions.snapshot.screenRecording
        case .keychain:
            switch settings.keychainAccess {
            case .noKeysStored, .ready: return .granted
            case .needsUnlock: return .unknown
            case .denied: return .denied
            }
        }
    }

    private func issue(for item: SetupItem) -> String? {
        switch item {
        case .microphone: return permissions.issues[.microphone]
        case .speechRecognition: return permissions.issues[.speechRecognition]
        case .systemAudio: return permissions.issues[.systemAudio]
        case .screenRecording: return permissions.issues[.screenRecording]
        case .keychain: return settings.keychainAccess == .denied ? settings.keychainErrorMessage : nil
        }
    }

    private func isOptional(_ item: SetupItem) -> Bool {
        item == .screenRecording && !requiresScreenRecording
    }

    private func request(_ item: SetupItem) async {
        guard requesting == nil else { return }
        requesting = item
        defer {
            requesting = nil
            bringToFront()
        }
        switch item {
        case .microphone: await permissions.requestMicrophone()
        case .speechRecognition: await permissions.requestSpeechRecognition()
        case .systemAudio: await permissions.requestSystemAudio()
        case .screenRecording: await permissions.requestScreenRecording()
        case .keychain: await settings.unlockStoredKeys()
        }
    }

    private func act(on item: SetupItem) {
        let current = status(of: item)
        switch item {
        case .microphone where current == .denied && permissions.issues[.microphone]?.contains("device policy") != true:
            permissions.openSettings(for: .microphone)
        case .speechRecognition where current == .denied && permissions.issues[.speechRecognition]?.contains("device policy") != true:
            permissions.openSettings(for: .speechRecognition)
        case .systemAudio where current == .denied:
            permissions.openSettings(for: .systemAudio)
        case .screenRecording where current == .denied:
            permissions.openSettings(for: .screenRecording)
        default:
            Task { await request(item) }
        }
    }

    private func buttonTitle(for item: SetupItem) -> String {
        let denied = status(of: item) == .denied
        switch item {
        case .keychain: return denied ? "Try again" : "Allow"
        case .microphone where permissions.issues[.microphone]?.contains("device policy") == true: return "Try again"
        case .speechRecognition where permissions.issues[.speechRecognition]?.contains("device policy") == true: return "Try again"
        default: return denied ? "Open Settings" : "Allow"
        }
    }

    private var requestableItems: [SetupItem] {
        visibleItems.filter { item in
            let current = status(of: item)
            switch item {
            case .keychain: return settings.keychainAccess == .needsUnlock
            default: return current == .unknown
            }
        }
    }

    private func allowAll() {
        let items = requestableItems
        Task {
            for item in items { await request(item) }
        }
    }

    private var permissionsStep: some View {
        scrollingStep {
            Text("Allow everything here")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.35)
            Text("macOS asks for these one at a time. You can change any of them in System Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.top, WP.Space.sm)

            VStack(spacing: WP.Space.sm) {
                ForEach(visibleItems, id: \.self) { item in
                    permissionRow(item)
                }
            }
            .padding(.top, WP.Space.xl)

            if settings.captureMicrophone && permissions.snapshot.microphone == .denied {
                Button("Continue without microphone") {
                    settings.captureMicrophone = false
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.top, WP.Space.md)
            }
        } footer: {
            if !missingRequired.isEmpty {
                Text("Still needed to start listening: \(missingRequired.map(title(of:)).joined(separator: ", ")).")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WP.Space.sm)
            }

            HStack {
                Button("Back") { step = .welcome }
                    .buttonStyle(.borderless)
                if requestableItems.count > 1 {
                    Button("Allow all") { allowAll() }
                        .buttonStyle(.bordered)
                        .disabled(requesting != nil)
                }
                Spacer()
                if !missingRequired.isEmpty {
                    Button("Skip for now") { goToAIStep() }
                        .buttonStyle(.borderless)
                }
                Button("Continue") { goToAIStep() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!missingRequired.isEmpty)
            }
        }
    }

    /// A step whose content can grow (long error messages, several rows) must not
    /// push its buttons out of the fixed-size window. The body scrolls and the
    /// footer stays put.
    private func scrollingStep<Body: View, Footer: View>(
        @ViewBuilder body: () -> Body,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    body()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(alignment: .leading, spacing: 0) {
                footer()
            }
            .padding(.top, WP.Space.md)
        }
        .contentPadding()
    }

    private func goToAIStep() {
        step = .ai
        Task {
            await Task.yield()
            apiKeyFocused = true
        }
    }

    private func permissionRow(_ item: SetupItem) -> some View {
        let current = status(of: item)
        let detail = issue(for: item)
        return HStack(alignment: .top, spacing: WP.Space.md) {
            Image(systemName: symbol(of: item))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(current == .granted ? Color.green : Color.accentColor)
                .frame(width: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: WP.Space.sm) {
                    Text(title(of: item))
                        .font(.system(size: 14, weight: .semibold))
                    if isOptional(item) {
                        Text("Optional")
                            .font(.system(size: 10, weight: .medium))
                            .chip(.neutral, horizontalPadding: 6, verticalPadding: 2)
                    }
                }
                Text(reason(of: item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if item == .systemAudio && current == .granted {
                    HStack(spacing: 4) {
                        Text("If you chose Don’t Allow, turn it on in")
                        Button("System Settings") { permissions.openSettings(for: .systemAudio) }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: WP.Space.md)

            if current == .granted {
                Label(item == .keychain && settings.keychainAccess == .noKeysStored ? "Nothing to unlock" : "Allowed",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.top, 2)
            } else {
                Button(buttonTitle(for: item)) { act(on: item) }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(requesting != nil)
            }
        }
        .padding(WP.Space.md)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var aiStep: some View {
        scrollingStep {
            Text("Connect AI when you’re ready")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.35)
            Text("Transcription works without AI. Add one provider key for answers, summaries, and action items.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.top, WP.Space.sm)

            Picker("Provider", selection: $selectedVendor) {
                Text("Gemini").tag(AIVendor.gemini)
                Text("Claude").tag(AIVendor.anthropic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, 28)
            .onChange(of: selectedVendor) { _, _ in
                apiKey = ""
            }
            .onAppear {
                if let saved = AIVendor.allCases.first(where: { settings.availableVendors.contains($0) }) {
                    selectedVendor = saved
                }
            }

            VStack(alignment: .leading, spacing: WP.Space.sm) {
                Text("\(selectedVendor.displayName) API key")
                    .font(.system(size: 12, weight: .semibold))
                SecureField(hasSavedKey ? "Saved in Keychain. Paste a new key to replace it." : (selectedVendor == .gemini ? "AIza…" : "sk-ant-…"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($apiKeyFocused)
                    .onSubmit(saveKeyAndFinish)

                HStack {
                    Label("Saved in the macOS Keychain, used only to call \(selectedVendor.displayName)", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Get a \(selectedVendor.displayName) key", destination: providerKeyURL)
                        .font(.system(size: 11, weight: .medium))
                }
                if let warning = keyFormatWarning {
                    Label(warning, systemImage: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, WP.Space.xl)

            if let error = settings.keychainErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WP.Space.md)
            }

        } footer: {
            footer(
                secondaryTitle: hasSavedKey ? "Back" : "Set up later",
                secondaryAction: hasSavedKey ? { step = .permissions } : finish,
                primaryTitle: hasSavedKey && trimmedKey.isEmpty ? "Done" : "Save and continue",
                primaryDisabled: !hasSavedKey && trimmedKey.isEmpty,
                primaryAction: saveKeyAndFinish
            )
        }
    }


    private var providerKeyURL: URL {
        switch selectedVendor {
        case .gemini:
            return URL(string: "https://aistudio.google.com/app/apikey")!
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSavedKey: Bool {
        settings.availableVendors.contains(selectedVendor)
    }

    /// Advice only, never a block: key formats can change, and a wrong guess
    /// here must not stop someone with a valid key.
    private var keyFormatWarning: String? {
        guard !trimmedKey.isEmpty else { return nil }
        if trimmedKey.contains(where: \.isWhitespace) {
            return "This key contains spaces or line breaks. Copy just the key."
        }
        switch selectedVendor {
        case .gemini where !trimmedKey.hasPrefix("AIza"):
            return "Gemini keys usually start with “AIza”. Check that you copied the whole key."
        case .anthropic where !trimmedKey.hasPrefix("sk-ant-"):
            return "Claude keys usually start with “sk-ant-”. Check that you copied the whole key."
        default:
            return nil
        }
    }

    private func saveKeyAndFinish() {
        guard !trimmedKey.isEmpty else {
            // Nothing typed and a key is already saved: just finish.
            if hasSavedKey { finish() }
            return
        }

        switch selectedVendor {
        case .gemini:
            settings.geminiAPIKey = trimmedKey
        case .anthropic:
            settings.anthropicAPIKey = trimmedKey
        }

        // The store reports a failed save through this message. Stay on the
        // screen so the user reads it instead of thinking the key was saved.
        guard settings.keychainErrorMessage == nil else { return }

        settings.activeModel = AIModelRegistry.defaultModel(availableVendors: [selectedVendor]).id
        finish()
    }

    /// Leaving with something still missing is allowed (macOS may block it, or
    /// the user chose to wait), but is remembered for this build so the window
    /// does not reappear at every launch. The overlay explains what is missing.
    private func finish() {
        if !missingRequired.isEmpty {
            settings.deferSetupForThisBuild()
        }
        onFinish()
    }

    private func footer(
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        primaryTitle: String,
        primaryDisabled: Bool = false,
        primaryAction: @escaping () -> Void
    ) -> some View {
        HStack {
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.borderless)
            }
            Spacer()
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(primaryDisabled)
        }
    }
}

private extension View {
    func contentPadding() -> some View {
        padding(.horizontal, 38)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
