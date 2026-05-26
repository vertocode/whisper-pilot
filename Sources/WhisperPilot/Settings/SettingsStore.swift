import Combine
import Foundation

/// When to start a new transcript line. `auto` lets the speech recognizer finalize on
/// its own (no time-based cutting — long single utterances stay on one line). The other
/// options force a line break after the chosen pause length.
enum UtteranceBoundary: String, CaseIterable, Codable, Sendable {
    case auto      // No time-based cycling. Trust SFSpeech's natural finalization.
    case quick     // 1.5 s
    case normal    // 3 s
    case relaxed   // 5 s
    case patient   // 10 s
    case minute    // 60 s

    /// Returns nil for `.auto` (no scheduled cycle).
    var seconds: TimeInterval? {
        switch self {
        case .auto: return nil
        case .quick: return 1.5
        case .normal: return 3
        case .relaxed: return 5
        case .patient: return 10
        case .minute: return 60
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto (no time-based cuts)"
        case .quick: return "Quick (1.5 s pause)"
        case .normal: return "Normal (3 s pause)"
        case .relaxed: return "Relaxed (5 s pause)"
        case .patient: return "Patient (10 s pause)"
        case .minute: return "Every minute"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Default. Lines are split only when the speech recognizer naturally finishes — no artificial cutting on pauses."
        case .quick: return "Snappy line breaks for crisp, fast-paced speech."
        case .normal: return "Splits lines on a 3-second pause."
        case .relaxed: return "Tolerates longer thinking pauses without splitting."
        case .patient: return "For very slow speakers or long monologues."
        case .minute: return "Forces a new line every 60 seconds, regardless of speech."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let geminiModel = "gemini.model"
        static let responseStyle = "response.style"
        static let captureMicrophone = "capture.microphone"
        static let forceScreenCaptureKitForSystemAudio = "capture.forceScreenCaptureKitForSystemAudio"
        static let alwaysOnTop = "overlay.alwaysOnTop"
        static let clickThrough = "overlay.clickThrough"
        static let hideFromScreenSharing = "overlay.hideFromScreenSharing"
        static let toggleOverlayShortcut = "shortcuts.toggleOverlay"
        static let localeIdentifier = "transcription.locale"
        static let geminiAPIKey = "gemini.api_key"
        static let microphoneDeviceUID = "capture.microphoneDeviceUID"
        static let utteranceBoundary = "transcription.utteranceBoundary"
        static let autoDetectQuestionsEnabled = "ai.autoDetectQuestionsEnabled"      // legacy bool — migrated into the per-channel pair below
        static let autoDetectQuestionsFromOther = "ai.autoDetectQuestionsFromOther"
        static let autoDetectQuestionsFromMe    = "ai.autoDetectQuestionsFromMe"
        static let includeTranscriptInPrompt = "ai.includeTranscriptInPrompt"
        static let includeSystemAudioInPrompt = "ai.includeSystemAudioInPrompt"
        static let includeChatHistoryInPrompt = "ai.includeChatHistoryInPrompt"
    }

    private let defaults: UserDefaults

    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: Keys.geminiModel) }
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
    /// audio never reaches the transcriber. Flipping this on forces SCK, which
    /// triggers macOS's Screen Recording permission prompt and reliably
    /// captures system audio in those environments.
    @Published var forceScreenCaptureKitForSystemAudio: Bool {
        didSet { defaults.set(forceScreenCaptureKitForSystemAudio, forKey: Keys.forceScreenCaptureKitForSystemAudio) }
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

    @Published var utteranceBoundary: UtteranceBoundary {
        didSet { defaults.set(utteranceBoundary.rawValue, forKey: Keys.utteranceBoundary) }
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

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    var geminiAPIKey: String? {
        get { KeychainHelper.get(Keys.geminiAPIKey) }
        set {
            KeychainHelper.set(newValue, forKey: Keys.geminiAPIKey)
            objectWillChange.send()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.geminiModel = defaults.string(forKey: Keys.geminiModel) ?? "gemini-2.5-flash"
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
        self.alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        self.clickThrough = defaults.object(forKey: Keys.clickThrough) as? Bool ?? false
        self.hideFromScreenSharing = defaults.object(forKey: Keys.hideFromScreenSharing) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.toggleOverlayShortcut),
           let stored = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            self.toggleOverlayShortcut = stored
        } else {
            self.toggleOverlayShortcut = .toggleOverlayDefault
        }
        self.localeIdentifier = defaults.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier
        self.microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
        self.utteranceBoundary = UtteranceBoundary(rawValue: defaults.string(forKey: Keys.utteranceBoundary) ?? "") ?? .auto
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
    }
}
