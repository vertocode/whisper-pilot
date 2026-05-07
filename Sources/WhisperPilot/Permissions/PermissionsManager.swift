import AVFoundation
import AppKit
import CoreGraphics
import Foundation

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
            screenRecording: currentScreenRecording()
        )
    }

    func requestMicrophone() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        snapshot.microphone = granted ? .granted : .denied
    }

    func requestScreenRecording() async {
        // macOS does not surface an SPI for "request screen recording" — the OS shows the
        // permission prompt the first time a process tries to capture. We trigger that by
        // calling `CGRequestScreenCaptureAccess`, which is the documented path.
        let granted = CGRequestScreenCaptureAccess()
        snapshot.screenRecording = granted ? .granted : .denied
        if !granted {
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

    private func currentScreenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .unknown
    }
}
