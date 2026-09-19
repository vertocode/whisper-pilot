import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech

enum PermissionStatus: Sendable, Equatable {
    case unknown
    case granted
    case denied
}

enum PermissionKind: Sendable, Equatable {
    case microphone
    case screenRecording
    case speechRecognition
    case systemAudio
}

struct PermissionsSnapshot: Sendable, Equatable {
    var microphone: PermissionStatus = .unknown
    var screenRecording: PermissionStatus = .unknown
    var speechRecognition: PermissionStatus = .unknown
    var systemAudio: PermissionStatus = .unknown
}

/// Every macOS permission the app needs is requested from here, and this is
/// only called from onboarding. Nothing else in the app should trigger a
/// system permission dialog.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var snapshot = PermissionsSnapshot()
    /// Plain-English reason the last request for a permission did not succeed.
    /// Cleared when the permission is granted.
    @Published private(set) var issues: [PermissionKind: String] = [:]

    private enum Keys {
        static let systemAudioRequested = "permissions.systemAudioRequested"
        static let screenRecordingRequested = "permissions.screenRecordingRequested"
    }

    private let defaults: UserDefaults
    /// Requests the user already answered with "no" during this run. macOS
    /// gives us no way to tell "denied" from "never asked" for these two, so
    /// we remember our own attempt.
    private var deniedThisRun: Set<PermissionKind> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Core Audio Process Taps (the audio-only capture path) need macOS 14.4.
    /// Older systems capture system audio through ScreenCaptureKit instead.
    static var processTapSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0))
    }

    /// True once onboarding has asked for Screen Recording, so a later probe
    /// cannot raise a brand-new system dialog.
    var hasAskedForScreenRecording: Bool {
        defaults.bool(forKey: Keys.screenRecordingRequested)
    }

    func refresh() async {
        snapshot = PermissionsSnapshot(
            microphone: currentMicrophone(),
            screenRecording: await currentScreenRecording(),
            speechRecognition: currentSpeechRecognition(),
            systemAudio: currentSystemAudio()
        )
        for kind in issues.keys where status(of: kind) == .granted {
            issues[kind] = nil
        }
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: return snapshot.microphone
        case .screenRecording: return snapshot.screenRecording
        case .speechRecognition: return snapshot.speechRecognition
        case .systemAudio: return snapshot.systemAudio
        }
    }

    func markScreenRecordingGranted() {
        snapshot.screenRecording = .granted
        issues[.screenRecording] = nil
    }

    // MARK: - Requests

    func requestMicrophone() async {
        wpInfo("Requesting microphone permission")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            snapshot.microphone = .denied
            issues[.microphone] = "Microphone access is blocked by a device policy (Screen Time or your organization). Whisper Pilot can't change that. Ask your administrator, or continue without the microphone."
            return
        }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        snapshot.microphone = granted ? .granted : .denied
        if granted {
            issues[.microphone] = nil
            wpInfo("Microphone permission granted")
        } else {
            issues[.microphone] = "Microphone access was not allowed. Turn on Whisper Pilot in System Settings → Privacy & Security → Microphone, or continue without the microphone."
            wpWarn("Microphone permission denied")
        }
    }

    func requestSpeechRecognition() async {
        wpInfo("Requesting Speech Recognition permission")
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let outcome = PermissionMapping.speechRequestOutcome(status)
        snapshot.speechRecognition = outcome.status
        issues[.speechRecognition] = outcome.issue
        if outcome.status == .granted {
            wpInfo("Speech Recognition permission granted")
        } else {
            wpWarn("Speech Recognition permission not granted (status \(status.rawValue))")
        }
    }

    /// macOS has no "request system audio access" call: the dialog appears the
    /// first time audio is captured. So we open the same audio tap the app uses
    /// for real sessions, hold it briefly so the dialog can show, and close it.
    func requestSystemAudio() async {
        guard #available(macOS 14.4, *) else {
            snapshot.systemAudio = .granted
            return
        }
        wpInfo("Requesting system audio access (opening a short Process Tap)")
        let tap = ProcessAudioCapture()
        do {
            try await tap.start()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            tap.stop()
            deniedThisRun.remove(.systemAudio)
            defaults.set(true, forKey: Keys.systemAudioRequested)
            snapshot.systemAudio = .granted
            issues[.systemAudio] = nil
        } catch {
            tap.stop()
            deniedThisRun.insert(.systemAudio)
            snapshot.systemAudio = .denied
            issues[.systemAudio] = "Whisper Pilot could not open system audio (\(error.localizedDescription)). Check that Whisper Pilot is on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            wpWarn("System audio request failed: \(error.localizedDescription)")
        }
    }

    func requestScreenRecording() async {
        wpInfo("Requesting Screen Recording permission")
        // macOS has no "request Screen Recording" call — the dialog appears the first time a
        // process tries to capture. Asking ScreenCaptureKit for shareable content triggers it.
        defaults.set(true, forKey: Keys.screenRecordingRequested)
        do {
            _ = try await SCShareableContent.current
            deniedThisRun.remove(.screenRecording)
            snapshot.screenRecording = .granted
            issues[.screenRecording] = nil
            wpInfo("Screen Recording permission granted")
        } catch {
            deniedThisRun.insert(.screenRecording)
            snapshot.screenRecording = .denied
            issues[.screenRecording] = "Screen Recording was not allowed. Turn on Whisper Pilot in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to quit and reopen Whisper Pilot afterwards."
            wpWarn("Screen Recording permission denied: \(error.localizedDescription)")
        }
    }

    // MARK: - System Settings links

    func openSettings(for kind: PermissionKind) {
        let pane: String
        switch kind {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .systemAudio: pane = "Privacy_AudioCapture"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func openScreenRecordingSettings() { openSettings(for: .screenRecording) }
    func openMicrophoneSettings() { openSettings(for: .microphone) }

    // MARK: - Passive checks (never show a dialog)

    private func currentMicrophone() -> PermissionStatus {
        PermissionMapping.microphone(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func currentSpeechRecognition() -> PermissionStatus {
        PermissionMapping.speechRecognition(SFSpeechRecognizer.authorizationStatus())
    }

    /// There is no public way to read the system-audio permission. We know the
    /// tap opened once (onboarding) or failed this run; anything else is unknown.
    private func currentSystemAudio() -> PermissionStatus {
        PermissionMapping.systemAudio(
            processTapSupported: Self.processTapSupported,
            openedBefore: defaults.bool(forKey: Keys.systemAudioRequested),
            deniedThisRun: deniedThisRun.contains(.systemAudio)
        )
    }

    /// Passive check for Screen Recording permission. Deliberately uses
    /// `CGPreflightScreenCaptureAccess` and NOT an `SCShareableContent` probe:
    /// the probe *triggers* the system dialog the first time it runs.
    private func currentScreenRecording() async -> PermissionStatus {
        PermissionMapping.screenRecording(
            alreadyGranted: snapshot.screenRecording == .granted,
            preflightGranted: snapshot.screenRecording == .granted ? false : CGPreflightScreenCaptureAccess(),
            deniedThisRun: deniedThisRun.contains(.screenRecording)
        )
    }
}
