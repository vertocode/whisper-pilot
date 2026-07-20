import AppKit
import Foundation
import SwiftUI

/// Polls the GitHub Releases API for a version newer than the running build and
/// exposes it as observable state. The Settings and Sessions headers render an
/// "Update to vX.Y.Z" button when one is found.
///
/// The app has no self-update mechanism (DMG / Homebrew distribution), so the
/// button opens the release page — from there the user downloads the DMG or
/// runs `brew upgrade --cask whisper-pilot`.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        /// Marketing version of the latest published release ("0.1.13").
        let version: String
        /// The release's GitHub page, where the DMG asset lives.
        let url: URL
    }

    /// Non-nil when a release newer than `AppInfo.version` is published.
    @Published private(set) var available: Release?

    /// Throttle: re-checking on every header render would hammer the API and
    /// the unauthenticated GitHub rate limit (60/hr/IP). Once per app run is
    /// almost always enough; the interval re-arms long sessions. A transport
    /// failure (launched offline, DNS hiccup) re-arms with the short retry
    /// instead — claiming the full 6 h on a failed check meant a launch-time
    /// network blip suppressed update discovery for the rest of the workday.
    private var nextCheckAllowedAt: Date = .distantPast
    private let minCheckInterval: TimeInterval = 6 * 60 * 60
    private let failureRetryInterval: TimeInterval = 5 * 60

    private init() {}

    /// Checks for a newer release, throttled. Safe to call from every
    /// `.task` on the header views — repeat calls inside the interval no-op.
    func checkForUpdates() async {
        guard Date() >= nextCheckAllowedAt else { return }
        // Claim the full interval up front so overlapping calls from the two
        // header views can't double-fire; shortened again on failure below.
        nextCheckAllowedAt = Date().addingTimeInterval(minCheckInterval)

        guard let endpoint = URL(string: "https://api.github.com/repos/vertocode/whisper-pilot/releases/latest") else { return }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // 404 = no releases yet; 403 = rate-limited. Neither is worth a
                // user-facing warning — the check just tries again next interval.
                wpInfo("Update check: GitHub returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            struct Wire: Decodable {
                let tagName: String
                let htmlUrl: String
                enum CodingKeys: String, CodingKey {
                    case tagName = "tag_name"
                    case htmlUrl = "html_url"
                }
            }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            let latest = wire.tagName.hasPrefix("v") ? String(wire.tagName.dropFirst()) : wire.tagName
            guard Self.isVersion(latest, newerThan: AppInfo.version),
                  let pageURL = URL(string: wire.htmlUrl) else {
                available = nil
                return
            }
            wpInfo("Update available: v\(latest) (running v\(AppInfo.version))")
            available = Release(version: latest, url: pageURL)
        } catch {
            // Offline / DNS / TLS failures are routine for an ambient app —
            // log for diagnostics, never surface a scary banner, retry soon.
            wpInfo("Update check failed: \(error.localizedDescription)")
            nextCheckAllowedAt = Date().addingTimeInterval(failureRetryInterval)
        }
    }

    /// Numeric dotted-version comparison ("0.1.13" vs "0.1.9" → true). Missing
    /// components count as 0; non-numeric components count as 0, so a malformed
    /// tag can never claim to be newer than a well-formed installed version.
    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Renders nothing until `UpdateChecker` finds a newer release, then shows a
/// prominent "Update to vX.Y.Z" button that opens the release page. Shared by
/// the Settings and Sessions headers; kicks off the (throttled) check itself
/// so call sites don't need their own `.task` wiring.
struct UpdateAvailableButton: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        Group {
            if let release = checker.available {
                Button {
                    NSWorkspace.shared.open(release.url)
                } label: {
                    Label("Update to v\(release.version)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("You're on v\(AppInfo.version). Opens the GitHub release page — download the DMG, or run: brew upgrade --cask whisper-pilot")
            }
        }
        .task { await checker.checkForUpdates() }
    }
}
