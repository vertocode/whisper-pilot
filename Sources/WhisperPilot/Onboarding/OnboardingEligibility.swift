/// One thing onboarding asks the user to allow.
enum SetupItem: CaseIterable, Hashable, Sendable {
    case microphone
    case speechRecognition
    case systemAudio
    case screenRecording
    case keychain
}

/// Which screen onboarding opens on.
enum OnboardingStart: Equatable, Sendable {
    case welcome
    case permissions
    case ai
}

enum OnboardingEligibility {
    /// Items the app cannot work properly without, given the user's settings.
    ///
    /// - Screen Recording is only *required* when system audio goes through
    ///   ScreenCaptureKit (forced in Settings, or macOS older than 14.4).
    ///   Otherwise it is offered as optional for "Answer screen".
    /// - System audio is required only on the Process Tap path.
    static func missing(
        captureMicrophone: Bool,
        requiresScreenRecording: Bool,
        processTapSupported: Bool,
        permissions: PermissionsSnapshot,
        keychain: KeychainAccess
    ) -> [SetupItem] {
        var items: [SetupItem] = []
        if captureMicrophone && permissions.microphone != .granted { items.append(.microphone) }
        if permissions.speechRecognition != .granted { items.append(.speechRecognition) }
        if !requiresScreenRecording && processTapSupported && permissions.systemAudio != .granted {
            items.append(.systemAudio)
        }
        if requiresScreenRecording && permissions.screenRecording != .granted { items.append(.screenRecording) }
        if keychain == .needsUnlock { items.append(.keychain) }
        return items
    }

    /// Whether to open onboarding at launch.
    ///
    /// - First run, or a newer onboarding version than the user last finished:
    ///   show it if a permission is missing OR no AI key is saved yet, so the
    ///   key step is never skipped just because every permission was already
    ///   granted (for example after macOS restarts the app mid-setup).
    /// - After that, only a Keychain that needs re-approval (a new build) brings
    ///   it back on its own; a permission the user turned off later is handled
    ///   from the overlay banner, not by reopening this window at every launch.
    /// - "Set up later" silences it for the current build.
    static func shouldPresent(
        completedVersion: Int,
        currentVersion: Int,
        deferredForThisBuild: Bool,
        missing: [SetupItem],
        hasAIKey: Bool
    ) -> Bool {
        guard !deferredForThisBuild else { return false }
        if missing.contains(.keychain) { return true }
        return completedVersion < currentVersion && (!missing.isEmpty || !hasAIKey)
    }

    /// Skips screens the user already went through. Someone who has granted
    /// anything has seen the welcome screen; someone with every permission
    /// granted only has the AI key step left.
    static func startPoint(
        completedVersion: Int,
        missing: [SetupItem],
        permissions: PermissionsSnapshot
    ) -> OnboardingStart {
        if completedVersion > 0 { return .permissions }
        if missing.isEmpty { return .ai }
        let anyGranted = [permissions.microphone, permissions.speechRecognition,
                          permissions.systemAudio, permissions.screenRecording].contains(.granted)
        return anyGranted ? .permissions : .welcome
    }
}
