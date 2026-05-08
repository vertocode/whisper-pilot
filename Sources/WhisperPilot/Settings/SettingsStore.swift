import Combine
import Foundation

enum AutoSendInterval: String, CaseIterable, Codable, Sendable {
    case off
    case every30s
    case every1m
    case every2m
    case every5m

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .every30s: return 30
        case .every1m: return 60
        case .every2m: return 120
        case .every5m: return 300
        }
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .every30s: return "Every 30 seconds"
        case .every1m: return "Every minute"
        case .every2m: return "Every 2 minutes"
        case .every5m: return "Every 5 minutes"
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
        static let autoSendInterval = "ai.autoSendInterval"
        static let microphoneDeviceUID = "capture.microphoneDeviceUID"
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

    @Published var autoSendInterval: AutoSendInterval {
        didSet { defaults.set(autoSendInterval.rawValue, forKey: Keys.autoSendInterval) }
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
        self.geminiModel = defaults.string(forKey: Keys.geminiModel) ?? "gemini-2.0-flash"
        self.responseStyle = ResponseStyle(rawValue: defaults.string(forKey: Keys.responseStyle) ?? "") ?? .concise
        self.captureMicrophone = defaults.object(forKey: Keys.captureMicrophone) as? Bool ?? false
        self.alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        self.clickThrough = defaults.object(forKey: Keys.clickThrough) as? Bool ?? false
        self.localeIdentifier = defaults.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier
        self.autoSendInterval = AutoSendInterval(rawValue: defaults.string(forKey: Keys.autoSendInterval) ?? "") ?? .off
        self.microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
    }
}
