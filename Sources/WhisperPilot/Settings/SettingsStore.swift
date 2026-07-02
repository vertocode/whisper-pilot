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
        static let safetyValveEnabled = "performance.safetyValveEnabled"
        static let safetyValveCPUPercent = "performance.safetyValveCPUPercent"
        static let safetyValveMemoryMB = "performance.safetyValveMemoryMB"
        static let alwaysTranscribeMic = "performance.alwaysTranscribeMic"
    }

    private let defaults: UserDefaults

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

    /// In-memory cache for API keys. Without this, every `settings.geminiAPIKey`
    /// access is a fresh `SecItemCopyMatching` call — and we have 5+ call sites
    /// in `AppCoordinator` alone (eager provider build, `refreshDerivedState`,
    /// prompt handlers). On an ad-hoc-signed local build, each Keychain hit
    /// after a rebuild can independently re-prompt the user because the access
    /// ACL is keyed by code signature. Caching collapses N reads per launch
    /// down to one. We invalidate the cache when the setter writes.
    ///
    /// Threading: this whole class is `@MainActor`, so the cache vars and
    /// `Loaded` flags don't need extra synchronization.
    private enum Cached<Value> {
        case empty
        case loaded(Value?)
    }
    private var cachedGeminiAPIKey: Cached<String> = .empty
    private var cachedAnthropicAPIKey: Cached<String> = .empty

    var geminiAPIKey: String? {
        get {
            switch cachedGeminiAPIKey {
            case .loaded(let v): return v
            case .empty:
                let v = KeychainHelper.get(Keys.geminiAPIKey)
                cachedGeminiAPIKey = .loaded(v)
                return v
            }
        }
        set {
            KeychainHelper.set(newValue, forKey: Keys.geminiAPIKey)
            cachedGeminiAPIKey = .loaded(newValue)
            objectWillChange.send()
        }
    }

    var anthropicAPIKey: String? {
        get {
            switch cachedAnthropicAPIKey {
            case .loaded(let v): return v
            case .empty:
                let v = KeychainHelper.get(Keys.anthropicAPIKey)
                cachedAnthropicAPIKey = .loaded(v)
                return v
            }
        }
        set {
            KeychainHelper.set(newValue, forKey: Keys.anthropicAPIKey)
            cachedAnthropicAPIKey = .loaded(newValue)
            objectWillChange.send()
        }
    }

    /// Which AI vendors have a configured API key right now. Used by the
    /// Settings model picker and the overlay's in-session model selector to
    /// filter `AIModelRegistry.all` down to the rows the user can actually
    /// use. Reading the keychain is cheap-but-not-free; callers that need
    /// this multiple times in a tight loop should snapshot the result.
    var availableVendors: Set<AIVendor> {
        var s: Set<AIVendor> = []
        if let k = geminiAPIKey, !k.isEmpty { s.insert(.gemini) }
        if let k = anthropicAPIKey, !k.isEmpty { s.insert(.anthropic) }
        return s
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Seed the keychain caches once at boot so the dozens of
        // `settings.geminiAPIKey` / `.anthropicAPIKey` reads later in the
        // launch path (eager provider build, refreshDerivedState wiring,
        // every prompt-related codepath) are served from memory instead of
        // hitting `SecItemCopyMatching` each time.
        let geminiKeyAtBoot = KeychainHelper.get(Keys.geminiAPIKey)
        let anthropicKeyAtBoot = KeychainHelper.get(Keys.anthropicAPIKey)
        self.cachedGeminiAPIKey = .loaded(geminiKeyAtBoot)
        self.cachedAnthropicAPIKey = .loaded(anthropicKeyAtBoot)

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
            var vendors: Set<AIVendor> = []
            if let k = geminiKeyAtBoot, !k.isEmpty { vendors.insert(.gemini) }
            if let k = anthropicKeyAtBoot, !k.isEmpty { vendors.insert(.anthropic) }
            let fallback = AIModelRegistry.defaultModel(availableVendors: vendors)
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
        self.safetyValveEnabled = defaults.object(forKey: Keys.safetyValveEnabled) as? Bool ?? true
        self.safetyValveCPUPercent = defaults.object(forKey: Keys.safetyValveCPUPercent) as? Double ?? 70
        self.safetyValveMemoryMB = defaults.object(forKey: Keys.safetyValveMemoryMB) as? Int ?? 1500
        self.alwaysTranscribeMic = defaults.object(forKey: Keys.alwaysTranscribeMic) as? Bool ?? true
    }
}
