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
        static let alwaysOnTop = "overlay.alwaysOnTop"
        static let clickThrough = "overlay.clickThrough"
        static let localeIdentifier = "transcription.locale"
        static let geminiAPIKey = "gemini.api_key"
        static let microphoneDeviceUID = "capture.microphoneDeviceUID"
        static let utteranceBoundary = "transcription.utteranceBoundary"
        static let autoDetectQuestionsEnabled = "ai.autoDetectQuestionsEnabled"
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

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop) }
    }

    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: Keys.clickThrough) }
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

    /// When true, the question detector's hits fire AI calls automatically. When
    /// false, detected questions are still highlighted in the transcript but no
    /// completion is requested.
    @Published var autoDetectQuestionsEnabled: Bool {
        didSet { defaults.set(autoDetectQuestionsEnabled, forKey: Keys.autoDetectQuestionsEnabled) }
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
        self.responseStyle = ResponseStyle(rawValue: defaults.string(forKey: Keys.responseStyle) ?? "") ?? .concise
        // Default to ON so the common first-time-test case (solo user speaking into
        // their Mac's mic) produces transcripts immediately. With this off, a user
        // sitting in silence on a Mac with no system audio playing sees a spinner
        // forever because nothing feeds the mixer. macOS will request mic permission
        // on the first Play; once granted, transcription "just works".
        self.captureMicrophone = defaults.object(forKey: Keys.captureMicrophone) as? Bool ?? true
        self.alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        self.clickThrough = defaults.object(forKey: Keys.clickThrough) as? Bool ?? false
        self.localeIdentifier = defaults.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier
        self.microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
        self.utteranceBoundary = UtteranceBoundary(rawValue: defaults.string(forKey: Keys.utteranceBoundary) ?? "") ?? .auto
        // AI behavior toggles default to true so the assistant works the way users
        // expect on first launch. Existing settings persist; only fresh installs see
        // the defaults.
        self.autoDetectQuestionsEnabled = defaults.object(forKey: Keys.autoDetectQuestionsEnabled) as? Bool ?? true
        self.includeTranscriptInPrompt = defaults.object(forKey: Keys.includeTranscriptInPrompt) as? Bool ?? true
        self.includeSystemAudioInPrompt = defaults.object(forKey: Keys.includeSystemAudioInPrompt) as? Bool ?? true
        self.includeChatHistoryInPrompt = defaults.object(forKey: Keys.includeChatHistoryInPrompt) as? Bool ?? true
    }
}
