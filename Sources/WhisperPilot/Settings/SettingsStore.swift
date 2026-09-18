import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        /// Legacy single-vendor model key. New code reads/writes `activeModel`;
        /// init() migrates a stored `geminiModel` value into `activeModel`.
        static let geminiModel = "gemini.model"
        /// Wire id of the currently-selected model from `AIModelRegistry`.
        /// Includes the vendor implicitly via the registry's id → vendor map.
        static let activeModel = "ai.activeModel"
        static let responseStyle = "response.style"
        static let captureMicrophone = "capture.microphone"
        static let forceScreenCaptureKitForSystemAudio = "capture.forceScreenCaptureKitForSystemAudio"
        static let alwaysOnTop = "overlay.alwaysOnTop"
        static let clickThrough = "overlay.clickThrough"
        static let hideFromScreenSharing = "overlay.hideFromScreenSharing"
        static let toggleOverlayShortcut = "shortcuts.toggleOverlay"
        static let answerScreenShortcut = "shortcuts.answerScreen"
        static let screenCaptureDisplayID = "capture.screenCaptureDisplayID"
        static let overlayLayoutMode = "overlay.layoutMode"
        static let overlayWidthFraction = "overlay.widthFraction"
        static let overlayHeightFraction = "overlay.heightFraction"
        static let overlayPosition = "overlay.position"
        static let overlayShowTranscript = "overlay.showTranscript"
        static let overlayShowExtraActions = "overlay.showExtraActions"
        static let overlayBackgroundOpacity = "overlay.backgroundOpacity"
        static let overlayTextColorHex = "overlay.textColorHex"
        static let overlayCompactChrome = "overlay.compactChrome"
        static let localeIdentifier = "transcription.locale"
        static let geminiAPIKey = "gemini.api_key"
        static let anthropicAPIKey = "anthropic.api_key"
        static let microphoneDeviceUID = "capture.microphoneDeviceUID"
        static let autoDetectQuestionsEnabled = "ai.autoDetectQuestionsEnabled"      // legacy bool — migrated into the per-channel pair below
        static let autoDetectQuestionsFromOther = "ai.autoDetectQuestionsFromOther"
        static let autoDetectQuestionsFromMe    = "ai.autoDetectQuestionsFromMe"
        static let includeTranscriptInPrompt = "ai.includeTranscriptInPrompt"
        static let includeSystemAudioInPrompt = "ai.includeSystemAudioInPrompt"
        static let includeChatHistoryInPrompt = "ai.includeChatHistoryInPrompt"
        static let translationEnabled = "translation.enabled"
        static let translationTarget = "translation.target"
        static let translationLayout = "translation.layout"
        static let translationColumnMode = "translation.columnMode"
        static let translationSourceWidthFraction = "translation.sourceWidthFraction"
        static let safetyValveEnabled = "performance.safetyValveEnabled"
        static let safetyValveCPUPercent = "performance.safetyValveCPUPercent"
        static let safetyValveMemoryMB = "performance.safetyValveMemoryMB"
        static let alwaysTranscribeMic = "performance.alwaysTranscribeMic"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let setupDeferredBuild = "onboarding.setupDeferredBuild"
        static let keychainApprovedBuild = "keychain.approvedBuild"
        /// One Keychain item holding every API key (JSON). macOS asks for approval
        /// once per item, so two separate items meant two rounds of password
        /// prompts. `geminiAPIKey` / `anthropicAPIKey` above are the old
        /// one-item-per-vendor accounts, read only to migrate into this one.
        static let apiKeysBundle = "api_keys"
        static let storedVendors = "keychain.storedVendors"
        static let legacyKeysMigrated = "keychain.legacyKeysMigrated"
    }

    /// Bump when onboarding starts asking for something new, so people who
    /// finished an older onboarding see it once more for the new items.
    nonisolated static let currentOnboardingVersion = 1

    private let defaults: UserDefaults

    private(set) var onboardingCompletedVersion: Int

    func completeOnboarding() {
        onboardingCompletedVersion = Self.currentOnboardingVersion
        defaults.set(Self.currentOnboardingVersion, forKey: Keys.onboardingCompletedVersion)
    }

    /// "Set up later" on the permissions screen. Remembered per build so the
    /// app does not nag on every launch, but comes back after an update.
    func deferSetupForThisBuild() {
        defaults.set(KeychainHelper.buildIdentity, forKey: Keys.setupDeferredBuild)
    }

    var isSetupDeferredForThisBuild: Bool {
        defaults.string(forKey: Keys.setupDeferredBuild) == KeychainHelper.buildIdentity
    }

    /// Wire id of the currently-selected model. Sourced from
    /// `AIModelRegistry.all` — any id not in the registry falls back to
    /// `AIModelRegistry.defaultModel(...)` on next launch. The vendor (Gemini
    /// vs. Anthropic) is derived from the registry, so callers don't need to
    /// track it separately.
    ///
    /// Renamed from `geminiModel` in v0.1.11. Old values are auto-migrated in
    /// `init()` so users coming from earlier builds keep their picked model.
    @Published var activeModel: String {
        didSet { defaults.set(activeModel, forKey: Keys.activeModel) }
    }

    @Published var responseStyle: ResponseStyle {
        didSet { defaults.set(responseStyle.rawValue, forKey: Keys.responseStyle) }
    }

    @Published var captureMicrophone: Bool {
        didSet { defaults.set(captureMicrophone, forKey: Keys.captureMicrophone) }
    }

    /// When true, we skip the Core Audio Process Tap path (macOS 14.4+) and
    /// always use ScreenCaptureKit for system audio. The Process Tap is
    /// preferred by default because it doesn't ask for Screen Recording
    /// permission, but on some Macs (notably some Mac mini configurations) it
    /// creates without error and then silently delivers zero frames — system
    /// audio never reaches the transcriber.
    ///
    /// Not user-facing. The coordinator's silent-tap watchdog manages this flag
    /// itself: when the tap is provably silent while the mic transcribes fine,
    /// it switches to SCK automatically (silently when Screen Recording is
    /// already granted, via a one-click confirmation note otherwise) and the
    /// choice persists so every later session starts on the working path.
    @Published var forceScreenCaptureKitForSystemAudio: Bool {
        didSet { defaults.set(forceScreenCaptureKitForSystemAudio, forKey: Keys.forceScreenCaptureKitForSystemAudio) }
    }

    /// Which monitor screen capture ("See my screen" and the ⌘⇧A answer-screen
    /// shortcut) grabs on a multi-display setup. `0` (the default) is the sentinel
    /// for "follow the monitor the pointer is on" — `kCGNullDirectDisplay` is 0, so
    /// it never collides with a real `CGDirectDisplayID`. Any non-zero value pins
    /// capture to that specific display regardless of where the user is looking.
    @Published var screenCaptureDisplayID: UInt32 {
        didSet { defaults.set(Int(screenCaptureDisplayID), forKey: Keys.screenCaptureDisplayID) }
    }

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop) }
    }

    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: Keys.clickThrough) }
    }

    /// When true, sets `NSWindow.sharingType = .none` on the overlay so screen-
    /// recording APIs (WebRTC `getDisplayMedia`, ScreenCaptureKit, QuickTime, etc.)
    /// don't see the window. Useful when sharing your screen in a meeting and you
    /// don't want personal notes / AI suggestions visible to the other side.
    @Published var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: Keys.hideFromScreenSharing) }
    }

    // MARK: - Overlay layout & appearance

    /// Set while `applyOverlayLayoutMode` is programmatically filling the
    /// individual appearance settings from a preset, so their `didSet`s don't
    /// each flip the mode back to `.custom` mid-application.
    private var isApplyingOverlayLayoutMode = false

    /// The active overlay layout preset. Selecting a non-custom mode fills every
    /// field below from `mode.preset`; editing any field afterward flips this to
    /// `.custom`. See `OverlayLayoutMode`.
    @Published var overlayLayoutMode: OverlayLayoutMode {
        didSet { defaults.set(overlayLayoutMode.rawValue, forKey: Keys.overlayLayoutMode) }
    }

    /// Overlay width as a fraction (0–1) of the screen's visible width. Applied
    /// live to the window when changed.
    @Published var overlayWidthFraction: Double {
        didSet {
            defaults.set(overlayWidthFraction, forKey: Keys.overlayWidthFraction)
            flipToCustomIfUserEdit()
        }
    }

    /// Overlay height as a fraction (0–1) of the screen's visible height.
    @Published var overlayHeightFraction: Double {
        didSet {
            defaults.set(overlayHeightFraction, forKey: Keys.overlayHeightFraction)
            flipToCustomIfUserEdit()
        }
    }

    /// Which screen corner/edge the overlay anchors to.
    @Published var overlayPosition: OverlayPosition {
        didSet {
            defaults.set(overlayPosition.rawValue, forKey: Keys.overlayPosition)
            flipToCustomIfUserEdit()
        }
    }

    /// Whether the live-transcript pane is shown. When off, the overlay is the AI
    /// conversation only — ideal for interview / glance modes.
    @Published var overlayShowTranscript: Bool {
        didSet {
            defaults.set(overlayShowTranscript, forKey: Keys.overlayShowTranscript)
            flipToCustomIfUserEdit()
        }
    }

    /// Whether the secondary composer action buttons (Summary, Action items) are
    /// shown. Help AI and the screenshot/send controls always remain.
    @Published var overlayShowExtraActions: Bool {
        didSet {
            defaults.set(overlayShowExtraActions, forKey: Keys.overlayShowExtraActions)
            flipToCustomIfUserEdit()
        }
    }

    /// Opacity (0.4–1.0) of the overlay's translucent background. Lower = more
    /// see-through. Text and controls stay fully opaque regardless.
    @Published var overlayBackgroundOpacity: Double {
        didSet {
            defaults.set(overlayBackgroundOpacity, forKey: Keys.overlayBackgroundOpacity)
            flipToCustomIfUserEdit()
        }
    }

    /// Overlay primary text color as `#RRGGBB`, or "" for the system default.
    @Published var overlayTextColorHex: String {
        didSet {
            defaults.set(overlayTextColorHex, forKey: Keys.overlayTextColorHex)
            flipToCustomIfUserEdit()
        }
    }

    /// Resolved overlay text color, or `nil` when the default should be used.
    var overlayTextColor: Color? {
        OverlayColor.color(fromHex: overlayTextColorHex)
    }

    /// Denser overlay chrome — tighter padding, smaller header/composer, hidden
    /// diagnostic subtitle — so a short window (Interview / Compact) stays usable.
    @Published var overlayCompactChrome: Bool {
        didSet {
            defaults.set(overlayCompactChrome, forKey: Keys.overlayCompactChrome)
            flipToCustomIfUserEdit()
        }
    }

    /// Fills every appearance field from `mode`'s preset, then records the mode.
    /// Guarded so the field `didSet`s don't relabel the result as `.custom`.
    /// `.custom` has no preset, so selecting it just records the mode and leaves
    /// the current field values in place.
    func applyOverlayLayoutMode(_ mode: OverlayLayoutMode) {
        guard let preset = mode.preset else {
            overlayLayoutMode = .custom
            return
        }
        isApplyingOverlayLayoutMode = true
        overlayWidthFraction = preset.widthFraction
        overlayHeightFraction = preset.heightFraction
        overlayPosition = preset.position
        overlayShowTranscript = preset.showTranscript
        overlayShowExtraActions = preset.showExtraActions
        overlayBackgroundOpacity = preset.backgroundOpacity
        overlayTextColorHex = preset.textColorHex
        overlayCompactChrome = preset.compactChrome
        isApplyingOverlayLayoutMode = false
        overlayLayoutMode = mode
    }

    /// Flips the active mode to `.custom` when the user edits an appearance field
    /// directly. No-op while a preset is being applied programmatically, or when
    /// the mode is already `.custom`.
    private func flipToCustomIfUserEdit() {
        guard !isApplyingOverlayLayoutMode, overlayLayoutMode != .custom else { return }
        overlayLayoutMode = .custom
    }

    /// Global keyboard shortcut for "toggle overlay visibility". Lives at the OS
    /// level (Carbon `RegisterEventHotKey`), so it works regardless of which app
    /// is frontmost and regardless of whether the overlay has click-through on.
    /// Default `⌘⇧Z`.
    @Published var toggleOverlayShortcut: ShortcutBinding {
        didSet {
            if let data = try? JSONEncoder().encode(toggleOverlayShortcut) {
                defaults.set(data, forKey: Keys.toggleOverlayShortcut)
            }
        }
    }

    /// Global keyboard shortcut for "answer what's on screen". Captures the
    /// current display and asks the AI to answer whatever question is visible.
    /// Same OS-level Carbon registration as `toggleOverlayShortcut`, so it fires
    /// from any app. Default `⌘⇧A`.
    @Published var answerScreenShortcut: ShortcutBinding {
        didSet {
            if let data = try? JSONEncoder().encode(answerScreenShortcut) {
                defaults.set(data, forKey: Keys.answerScreenShortcut)
            }
        }
    }

    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Keys.localeIdentifier) }
    }

    /// Stable Core Audio device UID for the chosen microphone. `nil` means "follow the
    /// system default input device".
    @Published var microphoneDeviceUID: String? {
        didSet {
            if let microphoneDeviceUID {
                defaults.set(microphoneDeviceUID, forKey: Keys.microphoneDeviceUID)
            } else {
                defaults.removeObject(forKey: Keys.microphoneDeviceUID)
            }
        }
    }

    /// Auto-fire the AI when "Other" (system audio) asks a question. Default on —
    /// matches the original copilot behavior people expect on first launch.
    @Published var autoDetectQuestionsFromOther: Bool {
        didSet { defaults.set(autoDetectQuestionsFromOther, forKey: Keys.autoDetectQuestionsFromOther) }
    }

    /// Auto-fire the AI when "Me" (microphone) asks a question. Default off —
    /// the user typically asks the AI by typing, and firing on every spoken
    /// question would double up when they're talking through a problem.
    @Published var autoDetectQuestionsFromMe: Bool {
        didSet { defaults.set(autoDetectQuestionsFromMe, forKey: Keys.autoDetectQuestionsFromMe) }
    }

    /// True when at least one auto-detect channel is enabled. Used by call sites
    /// that just want to know "is auto-detect on at all" without caring about
    /// which side.
    var autoDetectQuestionsEnabled: Bool {
        autoDetectQuestionsFromOther || autoDetectQuestionsFromMe
    }

    /// When false, the live transcript (and any resumed prior transcript) is
    /// dropped from the prompt context block — large token saver if the user only
    /// wants the AI to react to their typed prompts.
    @Published var includeTranscriptInPrompt: Bool {
        didSet { defaults.set(includeTranscriptInPrompt, forKey: Keys.includeTranscriptInPrompt) }
    }

    /// When false, system-audio (the "Other" speaker) transcript lines are not
    /// fed into ConversationContext, so they never appear in the AI prompt.
    /// Transcript display is unaffected — you still see what was said, the model
    /// just doesn't.
    @Published var includeSystemAudioInPrompt: Bool {
        didSet { defaults.set(includeSystemAudioInPrompt, forKey: Keys.includeSystemAudioInPrompt) }
    }

    /// When false, prior AI chat turns are excluded from each new prompt. Cheaper
    /// per call, but breaks "translate that" / "explain more" follow-ups because
    /// the model no longer sees what it just said.
    @Published var includeChatHistoryInPrompt: Bool {
        didSet { defaults.set(includeChatHistoryInPrompt, forKey: Keys.includeChatHistoryInPrompt) }
    }

    // MARK: - Live translation

    /// Master switch for the side-by-side translated transcript. Applies live —
    /// it only gates enqueueing and rendering, so flipping it mid-session takes
    /// effect on the next transcript line without a restart.
    ///
    /// When off, no `TranslationQueue` and no `TranslationSession` are ever
    /// constructed, so the audio and transcription paths are byte-for-byte what
    /// they were before the feature existed. Off is genuinely free.
    @Published var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Keys.translationEnabled) }
    }

    /// Language identifier the transcript is translated *into* (e.g. `pt-BR`).
    /// Empty means unset — the feature stays inert until the user picks one.
    ///
    /// Unlike the other two, this applies on the **next** session: the
    /// `TranslationSession` is built once per session from a fixed source →
    /// target pair, and swapping it mid-meeting would leave the lane holding
    /// two different languages. Mirrors how `resourceGovernorConfig` is read at
    /// session start.
    @Published var translationTargetIdentifier: String {
        didSet { defaults.set(translationTargetIdentifier, forKey: Keys.translationTarget) }
    }

    /// How source and translation are arranged in the transcript lane. Applies
    /// live — it's a pure view concern.
    @Published var translationLayout: TranslationLayout {
        didSet { defaults.set(translationLayout.rawValue, forKey: Keys.translationLayout) }
    }

    /// Which language(s) the transcript lane shows. Toggled from the chips in
    /// the transcript header, or by shoving the column divider to either edge.
    /// Applies live — pure view state.
    @Published var translationColumnMode: TranslationColumnMode {
        didSet { defaults.set(translationColumnMode.rawValue, forKey: Keys.translationColumnMode) }
    }

    /// Share of the row's text width given to the original language when the two
    /// sit side by side. Driven by dragging the column divider; clamped on write
    /// so a stored value can never render a column too narrow to read.
    @Published var translationSourceWidthFraction: Double {
        didSet {
            let clamped = Self.clampSourceFraction(translationSourceWidthFraction)
            if clamped != translationSourceWidthFraction {
                translationSourceWidthFraction = clamped
                return
            }
            defaults.set(translationSourceWidthFraction, forKey: Keys.translationSourceWidthFraction)
        }
    }

    static func clampSourceFraction(_ value: Double) -> Double {
        min(max(value, Double(TranslationLayout.minSourceWidthFraction)),
            Double(TranslationLayout.maxSourceWidthFraction))
    }

    /// True when translation is switched on, a target is chosen, and that target
    /// is actually a different language from what we're transcribing. The
    /// same-language case (transcribing `en-US`, targeting `en-GB`) would spend
    /// calls to reproduce the input, so it disables the feature instead.
    ///
    /// Says nothing about whether the language pack is downloaded — that's an
    /// async framework question, answered by `TranslationSupport.availability`.
    var translationIsConfigured: Bool {
        guard translationEnabled, !translationTargetIdentifier.isEmpty else { return false }
        return !TranslationSupport.isSameLanguage(localeIdentifier, translationTargetIdentifier)
    }

    // MARK: - Performance safety valve

    /// Master switch for the resource safety valve. When off, the monitor still
    /// samples for the live Diagnostics readout but never trips Tier-1/Tier-2 — the
    /// app reverts to its old no-limit behavior. Default on.
    @Published var safetyValveEnabled: Bool {
        didSet { defaults.set(safetyValveEnabled, forKey: Keys.safetyValveEnabled) }
    }

    /// Own-process CPU percentage above which the Tier-1 sustain clock starts. Maps
    /// to `ResourceGovernorConfig.cpuTier1Percent`. Can exceed 100 conceptually (one
    /// pinned core ≈ 100), but the Settings slider keeps it in a single-core range.
    @Published var safetyValveCPUPercent: Double {
        didSet { defaults.set(safetyValveCPUPercent, forKey: Keys.safetyValveCPUPercent) }
    }

    /// Resident-memory cap in megabytes; crossing it engages Tier-1 immediately. Stored
    /// in MB for a friendlier Settings control and converted to bytes for the governor.
    @Published var safetyValveMemoryMB: Int {
        didSet { defaults.set(safetyValveMemoryMB, forKey: Keys.safetyValveMemoryMB) }
    }

    /// Whether the microphone recognizer runs by default at session start. When off, a
    /// new session begins with the mic channel muted (system audio still transcribes) so
    /// users who rarely need their own voice transcribed avoid its cost without muting
    /// each session by hand. The in-session mic toggle still re-enables it on demand.
    @Published var alwaysTranscribeMic: Bool {
        didSet { defaults.set(alwaysTranscribeMic, forKey: Keys.alwaysTranscribeMic) }
    }

    /// Builds the governor config from the user's tunable thresholds. Sustain and
    /// escalation windows stay at their defaults — only the CPU% and memory caps are
    /// user-facing. Read at the start of each session so threshold edits take effect on
    /// the next listen.
    var resourceGovernorConfig: ResourceGovernorConfig {
        var config = ResourceGovernorConfig.default
        config.cpuTier1Percent = safetyValveCPUPercent
        config.memoryTier1Bytes = UInt64(max(0, safetyValveMemoryMB)) * 1_000_000
        return config
    }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    /// In-memory copy of the API keys. Reading a secret from the Keychain can
    /// make macOS show an approval dialog, so the app does that in exactly two
    /// places — `unlockStoredKeys()` (onboarding / an explicit button) and, at
    /// launch, only for a build the user already approved. Everything else
    /// (Settings, Sessions, the overlay, AI calls) reads this cache and never
    /// touches the Keychain.
    ///
    /// Threading: this whole class is `@MainActor`, so the cache vars don't
    /// need extra synchronization.
    private enum Cached<Value> {
        case empty
        case loaded(Value?)
    }
    private var cachedGeminiAPIKey: Cached<String> = .empty
    private var cachedAnthropicAPIKey: Cached<String> = .empty

    /// Non-nil when the last Keychain read or write failed. Surfaced next to
    /// the API-key fields and in onboarding — a silently dropped key would
    /// otherwise present as "AI features just don't work" with no explanation.
    @Published private(set) var keychainErrorMessage: String? = nil

    @Published private(set) var keychainAccess: KeychainAccess = .noKeysStored

    /// Cache-only: returns nil until the Keychain has been unlocked (or the key
    /// was saved in this run). Check `keychainAccess` to tell "no key" apart
    /// from "key exists but is still locked".
    var geminiAPIKey: String? {
        get {
            if case .loaded(let v) = cachedGeminiAPIKey { return v }
            return nil
        }
        set { saveKey(newValue, vendor: .gemini) }
    }

    var anthropicAPIKey: String? {
        get {
            if case .loaded(let v) = cachedAnthropicAPIKey { return v }
            return nil
        }
        set { saveKey(newValue, vendor: .anthropic) }
    }

    private struct KeyBundle: Codable {
        var gemini: String?
        var anthropic: String?

        var vendorIDs: [String] {
            var ids: [String] = []
            if !(gemini ?? "").isEmpty { ids.append(AIVendor.gemini.rawValue) }
            if !(anthropic ?? "").isEmpty { ids.append(AIVendor.anthropic.rawValue) }
            return ids
        }
    }

    private func saveKey(_ newValue: String?, vendor: AIVendor) {
        let vendorName = vendor.displayName
        // Writing to an item this build was never approved for would raise the
        // same macOS dialog, so refuse until it is unlocked.
        if keychainAccess == .needsUnlock || keychainAccess == .denied {
            keychainErrorMessage = "Your saved API key isn't unlocked yet — Whisper Pilot has not been allowed to open it. Choose “Allow Keychain access”, then try again."
            objectWillChange.send()
            return
        }
        let cleaned = (newValue ?? "").isEmpty ? nil : newValue
        var bundle = KeyBundle(gemini: geminiAPIKey, anthropic: anthropicAPIKey)
        switch vendor {
        case .gemini: bundle.gemini = cleaned
        case .anthropic: bundle.anthropic = cleaned
        }

        let status: OSStatus
        if bundle.vendorIDs.isEmpty {
            status = KeychainHelper.set(nil, forKey: Keys.apiKeysBundle)
        } else if let data = try? JSONEncoder().encode(bundle), let json = String(data: data, encoding: .utf8) {
            status = KeychainHelper.set(json, forKey: Keys.apiKeysBundle)
        } else {
            status = errSecParam
        }

        if status == errSecSuccess {
            switch vendor {
            case .gemini: cachedGeminiAPIKey = .loaded(cleaned)
            case .anthropic: cachedAnthropicAPIKey = .loaded(cleaned)
            }
            keychainErrorMessage = nil
            defaults.set(bundle.vendorIDs, forKey: Keys.storedVendors)
            // The bundle now holds everything; the old per-vendor items are ignored from here on.
            defaults.set(true, forKey: Keys.legacyKeysMigrated)
            if bundle.vendorIDs.isEmpty {
                keychainAccess = .noKeysStored
            } else {
                keychainAccess = .ready
                defaults.set(KeychainHelper.buildIdentity, forKey: Keys.keychainApprovedBuild)
            }
        } else {
            let action = cleaned == nil ? "Removing" : "Saving"
            keychainErrorMessage = "\(action) the \(vendorName) API key failed: \(KeychainHelper.describe(status)). Nothing was changed. Try again, or check Keychain Access for a locked or damaged login keychain."
        }
        objectWillChange.send()
    }

    /// Opens the saved keys so the app can use them. This is the ONE call that
    /// may show the macOS Keychain dialog — call it only from onboarding or a
    /// button the user pressed, after telling them why. The read runs off the
    /// main thread because it blocks until the user answers the dialog.
    @discardableResult
    func unlockStoredKeys() async -> KeychainAccess {
        let migrated = defaults.bool(forKey: Keys.legacyKeysMigrated)
        let outcome = await Task.detached { Self.loadFromKeychain(legacyMigrated: migrated) }.value
        apply(outcome)
        return outcome.access
    }

    private struct LoadOutcome {
        var bundle: KeyBundle?
        var access: KeychainAccess
        var errorMessage: String?
        var migratedLegacy = false
    }

    /// Pure Keychain I/O, no app state, so it can run on a background thread.
    /// Reads the single bundle item; if only the old one-item-per-vendor
    /// entries exist, reads those (one approval each, once) and rewrites them
    /// into the bundle.
    private nonisolated static func loadFromKeychain(legacyMigrated: Bool) -> LoadOutcome {
        if KeychainHelper.exists(Keys.apiKeysBundle) {
            switch KeychainHelper.read(Keys.apiKeysBundle) {
            case .value(let json):
                guard let bundle = try? JSONDecoder().decode(KeyBundle.self, from: Data(json.utf8)) else {
                    wpError("Keychain bundle could not be decoded")
                    return LoadOutcome(access: .denied, errorMessage: "Your saved API keys could not be read (the Keychain entry is damaged). Save the key again in Settings → AI Provider.")
                }
                return LoadOutcome(bundle: bundle, access: bundle.vendorIDs.isEmpty ? .noKeysStored : .ready)
            case .notFound:
                return LoadOutcome(bundle: KeyBundle(), access: .noKeysStored)
            case .denied:
                return LoadOutcome(access: .denied, errorMessage: deniedMessage(for: "saved"))
            case .failed(let status):
                return LoadOutcome(access: .denied, errorMessage: failedMessage(for: "saved", status: status))
            }
        }

        var bundle = KeyBundle()
        var readLegacy = false
        if !legacyMigrated {
            for (vendor, account) in [(AIVendor.gemini, Keys.geminiAPIKey), (AIVendor.anthropic, Keys.anthropicAPIKey)]
            where KeychainHelper.exists(account) {
                switch KeychainHelper.read(account) {
                case .value(let v):
                    readLegacy = true
                    if vendor == .gemini { bundle.gemini = v } else { bundle.anthropic = v }
                case .notFound:
                    break
                case .denied:
                    return LoadOutcome(access: .denied, errorMessage: deniedMessage(for: vendor.displayName))
                case .failed(let status):
                    return LoadOutcome(access: .denied, errorMessage: failedMessage(for: vendor.displayName, status: status))
                }
            }
        }
        guard readLegacy, !bundle.vendorIDs.isEmpty else {
            return LoadOutcome(bundle: KeyBundle(), access: .noKeysStored)
        }
        var outcome = LoadOutcome(bundle: bundle, access: .ready)
        if let data = try? JSONEncoder().encode(bundle), let json = String(data: data, encoding: .utf8),
           KeychainHelper.set(json, forKey: Keys.apiKeysBundle) == errSecSuccess {
            outcome.migratedLegacy = true
        } else {
            // Keys still work for this run; the move is retried next launch.
            wpWarn("Keychain: could not move API keys into the single bundle item")
        }
        return outcome
    }

    private nonisolated static func deniedMessage(for what: String) -> String {
        let subject = what == "saved" ? "your saved API keys" : "your \(what) API key"
        return "macOS did not let Whisper Pilot open \(subject). AI answers stay off until you allow it. Press “Allow Keychain access” and choose Allow or Always Allow."
    }

    private nonisolated static func failedMessage(for what: String, status: OSStatus) -> String {
        let subject = what == "saved" ? "your saved API keys" : "your \(what) API key"
        return "Could not read \(subject) from the Keychain: \(KeychainHelper.describe(status)). Try again, or check Keychain Access for a locked or damaged login keychain."
    }

    private func apply(_ outcome: LoadOutcome) {
        if let bundle = outcome.bundle {
            cachedGeminiAPIKey = .loaded(bundle.gemini)
            cachedAnthropicAPIKey = .loaded(bundle.anthropic)
            defaults.set(bundle.vendorIDs, forKey: Keys.storedVendors)
        }
        if outcome.migratedLegacy {
            defaults.set(true, forKey: Keys.legacyKeysMigrated)
        }
        keychainErrorMessage = outcome.errorMessage
        keychainAccess = outcome.access
        if outcome.access == .ready {
            defaults.set(KeychainHelper.buildIdentity, forKey: Keys.keychainApprovedBuild)
        }
        objectWillChange.send()
    }

    /// Vendors that have a saved key, answered without opening any secret.
    /// Uses the list remembered in UserDefaults, plus the old per-vendor items
    /// (attributes only) until they've been moved into the bundle.
    private nonisolated static func configuredVendors(defaults: UserDefaults) -> Set<AIVendor> {
        var vendors = Set((defaults.stringArray(forKey: Keys.storedVendors) ?? []).compactMap(AIVendor.init(rawValue:)))
        if !defaults.bool(forKey: Keys.legacyKeysMigrated) {
            if KeychainHelper.exists(Keys.geminiAPIKey) { vendors.insert(.gemini) }
            if KeychainHelper.exists(Keys.anthropicAPIKey) { vendors.insert(.anthropic) }
        }
        if vendors.isEmpty, KeychainHelper.exists(Keys.apiKeysBundle) {
            // The list was lost (defaults wiped) — assume both until unlocked.
            vendors = Set(AIVendor.allCases)
        }
        return vendors
    }

    /// Launch-time step. Keys are read here only if the user already approved
    /// this exact build, which means macOS will not ask again. Otherwise the
    /// state becomes `.needsUnlock` and onboarding asks, with an explanation.
    private func restoreKeychainAccess() {
        guard !Self.configuredVendors(defaults: defaults).isEmpty else {
            keychainAccess = .noKeysStored
            return
        }
        let build = KeychainHelper.buildIdentity
        guard build != KeychainHelper.unknownBuildIdentity,
              defaults.string(forKey: Keys.keychainApprovedBuild) == build else {
            keychainAccess = .needsUnlock
            return
        }
        apply(Self.loadFromKeychain(legacyMigrated: defaults.bool(forKey: Keys.legacyKeysMigrated)))
    }

    /// Which AI vendors have a configured API key right now. Used by the
    /// Settings model picker and the overlay's in-session model selector to
    /// filter `AIModelRegistry.all` down to the rows the user can actually
    /// use. Reading the keychain is cheap-but-not-free; callers that need
    /// this multiple times in a tight loop should snapshot the result.
    /// Uses existence checks rather than reads. Every caller here only needs to
    /// know *whether* a vendor is configured, and reading the secret to answer
    /// that costs the user an authorization dialog per vendor on builds macOS
    /// doesn't recognize — which is every ad-hoc-signed build.
    var availableVendors: Set<AIVendor> {
        var s: Set<AIVendor> = []
        if hasGeminiAPIKey { s.insert(.gemini) }
        if hasAnthropicAPIKey { s.insert(.anthropic) }
        return s
    }

    /// Existence of a configured key, answered without decrypting it. Served
    /// from the value cache when the secret has already been read for a real
    /// reason, so a later AI call doesn't re-query.
    var hasGeminiAPIKey: Bool {
        if case .loaded(let v) = cachedGeminiAPIKey { return !(v ?? "").isEmpty }
        return Self.configuredVendors(defaults: defaults).contains(.gemini)
    }

    var hasAnthropicAPIKey: Bool {
        if case .loaded(let v) = cachedAnthropicAPIKey { return !(v ?? "").isEmpty }
        return Self.configuredVendors(defaults: defaults).contains(.anthropic)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingCompletedVersion)
        // Existence checks only (attributes, never the secret): the model choice
        // below needs to know which vendors have a key, and this must not cost
        // the user a macOS dialog. The secrets themselves are opened at the end
        // of init, and only for a build the user already approved.
        let configuredAtBoot = Self.configuredVendors(defaults: defaults)

        // Resolve the active model in priority order:
        //   1. New unified key set by post-v0.1.11 builds.
        //   2. Legacy `gemini.model` value set by older builds (one-shot
        //      migration; preserved as-is because the registry shares the
        //      same wire ids for Gemini models).
        //   3. Registry default — picks a sensible model for whichever
        //      vendor(s) have keys configured, falling through to the first
        //      registered model on a fresh install with no keys.
        let storedActive = defaults.string(forKey: Keys.activeModel)
        let legacyGemini = defaults.string(forKey: Keys.geminiModel)
        if let id = storedActive, AIModelRegistry.model(for: id) != nil {
            self.activeModel = id
        } else if let id = legacyGemini, AIModelRegistry.model(for: id) != nil {
            self.activeModel = id
            defaults.set(id, forKey: Keys.activeModel)
        } else {
            let fallback = AIModelRegistry.defaultModel(availableVendors: configuredAtBoot)
            self.activeModel = fallback.id
            defaults.set(fallback.id, forKey: Keys.activeModel)
        }
        // Default to Auto for new installs — lets the model right-size each
        // answer instead of forcing a fixed length. Existing users keep
        // whatever style they previously selected.
        self.responseStyle = ResponseStyle(rawValue: defaults.string(forKey: Keys.responseStyle) ?? "") ?? .auto
        // Default to ON so the common first-time-test case (solo user speaking into
        // their Mac's mic) produces transcripts immediately. With this off, a user
        // sitting in silence on a Mac with no system audio playing sees a spinner
        // forever because nothing feeds the mixer. macOS will request mic permission
        // on the first Play; once granted, transcription "just works".
        self.captureMicrophone = defaults.object(forKey: Keys.captureMicrophone) as? Bool ?? true
        // Default to false: ProcessTap is genuinely better when it works (no
        // Screen Recording prompt, lower overhead). Users on Macs where it
        // silently fails can flip this in Settings → Capture.
        self.forceScreenCaptureKitForSystemAudio = defaults.object(forKey: Keys.forceScreenCaptureKitForSystemAudio) as? Bool ?? false
        // 0 = follow the monitor with the pointer (default). A previously-stored
        // specific display ID survives reconnects; if that monitor is gone at
        // capture time, the coordinator falls back gracefully.
        self.screenCaptureDisplayID = UInt32(defaults.object(forKey: Keys.screenCaptureDisplayID) as? Int ?? 0)
        self.alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        self.clickThrough = defaults.object(forKey: Keys.clickThrough) as? Bool ?? false
        self.hideFromScreenSharing = defaults.object(forKey: Keys.hideFromScreenSharing) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.toggleOverlayShortcut),
           let stored = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            self.toggleOverlayShortcut = stored
        } else {
            self.toggleOverlayShortcut = .toggleOverlayDefault
        }
        if let data = defaults.data(forKey: Keys.answerScreenShortcut),
           let stored = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            self.answerScreenShortcut = stored
        } else {
            self.answerScreenShortcut = .answerScreenDefault
        }
        // Overlay layout & appearance. Installs that never picked a mode get
        // the Sidebar preset (a third of the screen wide, full height, right
        // edge) — the best out-of-box arrangement next to a meeting window.
        // Field defaults mirror that preset so the Settings sliders and the
        // window frame agree on first launch. A stored mode (including `.custom`
        // written the first time the user dragged/resized the window) always
        // wins, so existing tuned setups aren't yanked into the new default.
        self.overlayLayoutMode = OverlayLayoutMode(rawValue: defaults.string(forKey: Keys.overlayLayoutMode) ?? "") ?? .sidebar
        self.overlayWidthFraction = defaults.object(forKey: Keys.overlayWidthFraction) as? Double ?? 1.0 / 3.0
        self.overlayHeightFraction = defaults.object(forKey: Keys.overlayHeightFraction) as? Double ?? 1.0
        self.overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: Keys.overlayPosition) ?? "") ?? .right
        self.overlayShowTranscript = defaults.object(forKey: Keys.overlayShowTranscript) as? Bool ?? true
        self.overlayShowExtraActions = defaults.object(forKey: Keys.overlayShowExtraActions) as? Bool ?? true
        // 0.92 matches the Sidebar preset (the fresh-install default mode above).
        self.overlayBackgroundOpacity = defaults.object(forKey: Keys.overlayBackgroundOpacity) as? Double ?? 0.92
        self.overlayTextColorHex = defaults.string(forKey: Keys.overlayTextColorHex) ?? ""
        self.overlayCompactChrome = defaults.object(forKey: Keys.overlayCompactChrome) as? Bool ?? false
        self.localeIdentifier = defaults.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier
        self.microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
        // AI behavior toggles default to true so the assistant works the way users
        // expect on first launch. Existing settings persist; only fresh installs see
        // the defaults.
        // Migration path: the original single boolean `autoDetectQuestionsEnabled`
        // mapped to "auto-fire on Other only". If the user previously customized
        // it, honor that intent. Otherwise default Other=on / Me=off.
        let legacyEnabled = defaults.object(forKey: Keys.autoDetectQuestionsEnabled) as? Bool
        self.autoDetectQuestionsFromOther = defaults.object(forKey: Keys.autoDetectQuestionsFromOther) as? Bool
            ?? legacyEnabled
            ?? true
        self.autoDetectQuestionsFromMe = defaults.object(forKey: Keys.autoDetectQuestionsFromMe) as? Bool ?? false
        self.includeTranscriptInPrompt = defaults.object(forKey: Keys.includeTranscriptInPrompt) as? Bool ?? true
        self.includeSystemAudioInPrompt = defaults.object(forKey: Keys.includeSystemAudioInPrompt) as? Bool ?? true
        self.includeChatHistoryInPrompt = defaults.object(forKey: Keys.includeChatHistoryInPrompt) as? Bool ?? true
        // Safety valve defaults track the PRD's tier values: on, CPU 70%, memory 1.5 GB.
        // `alwaysTranscribeMic` defaults on so existing behavior (mic transcribed by
        // default) is unchanged for users who never touch the setting.
        // Translation is off on fresh installs: it's a deliberate opt-in that
        // costs CPU, and most sessions are single-language. No target is
        // guessed — picking one silently would be a surprising default for a
        // feature the user hasn't asked for yet.
        self.translationEnabled = defaults.object(forKey: Keys.translationEnabled) as? Bool ?? false
        self.translationTargetIdentifier = defaults.string(forKey: Keys.translationTarget) ?? ""
        self.translationLayout = TranslationLayout(rawValue: defaults.string(forKey: Keys.translationLayout) ?? "") ?? .auto
        self.translationColumnMode = TranslationColumnMode(rawValue: defaults.string(forKey: Keys.translationColumnMode) ?? "") ?? .both
        self.translationSourceWidthFraction = Self.clampSourceFraction(
            defaults.object(forKey: Keys.translationSourceWidthFraction) as? Double
                ?? Double(TranslationLayout.defaultSourceWidthFraction)
        )
        self.safetyValveEnabled = defaults.object(forKey: Keys.safetyValveEnabled) as? Bool ?? true
        self.safetyValveCPUPercent = defaults.object(forKey: Keys.safetyValveCPUPercent) as? Double ?? 70
        self.safetyValveMemoryMB = defaults.object(forKey: Keys.safetyValveMemoryMB) as? Int ?? 1500
        self.alwaysTranscribeMic = defaults.object(forKey: Keys.alwaysTranscribeMic) as? Bool ?? true
        restoreKeychainAccess()
    }
}
