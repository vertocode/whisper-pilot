import AVFoundation
import Foundation
import Speech

/// Turns raw macOS answers into what the app shows. Kept free of any system
/// call so it can be tested without a permission dialog.
enum PermissionMapping {
    static func microphone(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    static func speechRecognition(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// macOS has no way to read the system-audio permission, so this is our own
    /// memory: the tap opened once, or failed during this run.
    static func systemAudio(processTapSupported: Bool, openedBefore: Bool, deniedThisRun: Bool) -> PermissionStatus {
        guard processTapSupported else { return .granted }
        if openedBefore { return .granted }
        return deniedThisRun ? .denied : .unknown
    }

    /// `alreadyGranted` is a live probe that succeeded earlier in this run; it
    /// wins over the preflight call, which can stay stale until a relaunch.
    static func screenRecording(alreadyGranted: Bool, preflightGranted: Bool, deniedThisRun: Bool) -> PermissionStatus {
        if alreadyGranted || preflightGranted { return .granted }
        return deniedThisRun ? .denied : .unknown
    }

    /// Result of asking for Speech Recognition: the status to show and, when it
    /// was not granted, the sentence that tells the user what to do.
    static func speechRequestOutcome(_ status: SFSpeechRecognizerAuthorizationStatus) -> (status: PermissionStatus, issue: String?) {
        switch status {
        case .authorized:
            return (.granted, nil)
        case .restricted:
            return (.denied, "Speech Recognition is blocked by a device policy (Screen Time or your organization). Whisper Pilot can't change that.")
        case .denied, .notDetermined:
            return (.denied, "Speech Recognition was not allowed. Turn on Whisper Pilot in System Settings → Privacy & Security → Speech Recognition.")
        @unknown default:
            return (.denied, "macOS returned an unknown Speech Recognition status. Check System Settings → Privacy & Security → Speech Recognition.")
        }
    }
}
