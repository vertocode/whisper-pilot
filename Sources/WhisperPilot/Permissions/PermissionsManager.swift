import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PermissionStatus: Sendable, Equatable {
    case unknown
    case granted
    case denied
}

enum PermissionKind: Sendable, Equatable {
    case microphone
    case screenRecording
}

struct PermissionsSnapshot: Sendable, Equatable {
    var microphone: PermissionStatus = .unknown
    var screenRecording: PermissionStatus = .unknown
}

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var snapshot = PermissionsSnapshot()

    func refresh() async {
        snapshot = PermissionsSnapshot(
            microphone: currentMicrophone(),
            screenRecording: await currentScreenRecording()
        )
    }

    func markScreenRecordingGranted() {
        snapshot.screenRecording = .granted
    }

    func requestMicrophone() async {
        wpInfo("Requesting microphone permission")
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        snapshot.microphone = granted ? .granted : .denied
        if granted {
            wpInfo("Microphone permission granted")
        } else {
            wpWarn("Microphone permission denied")
        }
    }

    func requestScreenRecording() async {
        wpInfo("Requesting Screen Recording permission")
        // macOS does not surface an SPI for "request Screen Recording" — the OS shows the
        // permission prompt the first time a process tries to capture. We trigger that by
        // asking ScreenCaptureKit for shareable content; the prompt appears on first run,
        // and on subsequent denied runs we deep-link to System Settings.
        do {
            _ = try await SCShareableContent.current
            snapshot.screenRecording = .granted
            wpInfo("Screen Recording permission granted")
        } catch {
            snapshot.screenRecording = .denied
            wpWarn("Screen Recording permission still denied; opening System Settings")
            openScreenRecordingSettings()
        }
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func currentMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Live probe for Screen Recording permission. We deliberately do *not* call
    /// `CGPreflightScreenCaptureAccess` — its result is cached at app launch and never
    /// reflects permission grants made while the app is running, which produced "stuck on
    /// needs-permission" reports from users who had already granted access.
    private func currentScreenRecording() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            return .unknown
        }
    }
}
