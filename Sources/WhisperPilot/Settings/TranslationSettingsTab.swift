import SwiftUI
import Translation

/// Settings pane for the live translated transcript.
///
/// Owns the language-pack download flow, which is the one part of the feature
/// that has to live in a view. `TranslationSession(installedSource:target:)` —
/// the init the runtime hot path uses — reports `canRequestDownloads == false`
/// and can never raise the system download sheet. Verified across a CLI binary,
/// an accessory app, and a regular app with a key window: it's the init's
/// contract, not an `LSUIElement` limitation.
///
/// Only a session handed over by SwiftUI's `.translationTask` reports true, so
/// the download button lives here and nowhere else. Everything after the
/// download — the actual live captioning — is actor-owned as usual.
struct TranslationSettingsTab: View {
    @ObservedObject var store: SettingsStore
    /// Notifies the coordinator that the enable toggle changed, so a running
    /// session can pick the feature up (or drop it) without a restart.
    var onConfigurationChanged: () -> Void

    @State private var targets: [(identifier: String, name: String)] = []
    @State private var availability: TranslationAvailability?
    @State private var isCheckingAvailability = false

    var body: some View {
        Form {
            Section("Live translation") {
                Toggle("Show a translated transcript", isOn: $store.translationEnabled)
                FormHint("Adds a second column to the live transcript with everything the other side says, translated on-device. Your own microphone lines aren't translated — you already know what you said, and skipping them halves the work.\n\nWhen this is off, no translation session is created at all: the transcription pipeline runs exactly as it did before the feature existed.")
            }

            Section("Language") {
                Picker("Translate into", selection: $store.translationTargetIdentifier) {
                    Text("Choose a language…").tag("")
                    ForEach(targets, id: \.identifier) { target in
                        Text(target.name).tag(target.identifier)
                    }
                }
                .disabled(targets.isEmpty)

                statusRow

                FormHint("Translated from the Locale set in General (currently \(languageName(store.localeIdentifier))), which is the language the speech recognizer is listening for. Changing the target applies the next time you press ▶ — a session translates one fixed pair, so switching mid-meeting would leave the transcript holding two languages.")
            }

            Section("Layout") {
                Picker("Arrangement", selection: $store.translationLayout) {
                    ForEach(TranslationLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                FormHint(store.translationLayout.summary + "\n\nThe default Sidebar overlay is a third of the screen wide, which leaves each column around 34 characters — so Auto stacks there and switches to columns in the wider Standard and Focus layouts, or when you widen the window yourself.")
            }
        }
        .formStyle(.grouped)
        .task { await loadTargets() }
        .onChange(of: store.translationTargetIdentifier) { _, _ in
            Task { await refreshAvailability() }
            onConfigurationChanged()
        }
        .onChange(of: store.translationEnabled) { _, _ in
            onConfigurationChanged()
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch availability {
        case nil:
            if store.translationTargetIdentifier.isEmpty {
                statusLabel(icon: "questionmark.circle", tint: .secondary,
                            text: "Pick a language to see whether it's ready to use.")
            } else if isCheckingAvailability {
                statusLabel(icon: "clock", tint: .secondary, text: "Checking…")
            }

        case .installed:
            statusLabel(icon: "checkmark.circle.fill", tint: .green,
                        text: "Installed — ready to use.")

        case .downloadRequired:
            VStack(alignment: .leading, spacing: WP.Space.sm) {
                statusLabel(icon: "arrow.down.circle", tint: .orange,
                            text: "Language pack not downloaded yet.")
                if #available(macOS 26.0, *) {
                    TranslationDownloadButton(
                        source: store.localeIdentifier,
                        target: store.translationTargetIdentifier,
                        onFinished: { Task { await refreshAvailability() } }
                    )
                }
                FormHint("macOS handles the download and asks for confirmation. The pack is shared with Safari, Messages, and the Translate app, so it's a one-time cost per language for your whole Mac — not per app.")
            }

        case .unsupported:
            statusLabel(icon: "xmark.circle", tint: .red,
                        text: "macOS doesn't offer translation between \(languageName(store.localeIdentifier)) and \(languageName(store.translationTargetIdentifier)).")

        case .unavailableOnThisSystem:
            statusLabel(icon: "exclamationmark.triangle", tint: .orange,
                        text: "Live translation needs macOS 26 or later. Everything else in Whisper Pilot works as normal.")
        }
    }

    private func statusLabel(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WP.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(WP.TextStyle.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Loading

    private func loadTargets() async {
        targets = await TranslationSupport.supportedTargets()
        await refreshAvailability()
    }

    private func refreshAvailability() async {
        guard !store.translationTargetIdentifier.isEmpty else {
            availability = nil
            return
        }
        isCheckingAvailability = true
        availability = await TranslationSupport.availability(
            from: store.localeIdentifier,
            to: store.translationTargetIdentifier
        )
        isCheckingAvailability = false
    }

    private func languageName(_ identifier: String) -> String {
        guard !identifier.isEmpty else { return "—" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// The only place in the app that can raise the system language-pack download
/// sheet. Setting a non-nil configuration is what starts `.translationTask`;
/// the sheet appears inside `prepareTranslation()` and blocks until the user
/// accepts or cancels.
@available(macOS 26.0, *)
private struct TranslationDownloadButton: View {
    let source: String
    let target: String
    var onFinished: () -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.xs) {
            Button {
                guard
                    let src = TranslationSupport.language(from: source),
                    let dst = TranslationSupport.language(from: target)
                else { return }
                errorMessage = nil
                isDownloading = true
                configuration = TranslationSession.Configuration(source: src, target: dst)
            } label: {
                HStack(spacing: WP.Space.xs) {
                    if isDownloading { ProgressView().controlSize(.small) }
                    Text(isDownloading ? "Waiting for macOS…" : "Download language…")
                }
            }
            .disabled(isDownloading)

            if let errorMessage {
                Text(errorMessage)
                    .font(WP.TextStyle.body)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                await MainActor.run {
                    errorMessage = "Download didn't complete: \(error.localizedDescription)"
                }
            }
            // Deliberately NOT checking `session.isReady` here. Measured
            // behavior: after a download that genuinely succeeded, `isReady` on
            // the very session that performed it still reported false, while a
            // fresh `LanguageAvailability` query correctly reported
            // `.installed`. Re-query rather than trust the stale session.
            //
            // The inverse trap is just as real: `prepareTranslation()`
            // returning without throwing does NOT prove the pack installed.
            // The availability re-check below is the only reliable signal.
            await MainActor.run {
                isDownloading = false
                configuration = nil
                onFinished()
            }
        }
    }
}
