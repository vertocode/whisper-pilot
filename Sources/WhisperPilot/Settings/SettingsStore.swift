import Combine
import Foundation

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
    }
}
