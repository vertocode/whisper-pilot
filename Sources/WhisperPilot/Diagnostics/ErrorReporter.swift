import AppKit
import SwiftUI

/// Offers to report a detected problem as a GitHub issue.
///
/// Opens a pre-filled "new issue" page in the browser instead of calling the
/// GitHub API. An API call needs a token, and a token shipped inside an app
/// can be extracted and abused by anyone. The browser route needs no secret,
/// and the user sees exactly what will be posted before they submit it.
@MainActor
final class ErrorReporter {
    static let shared = ErrorReporter()

    private static let repo = "vertocode/whisper-pilot"
    // Keeps the pre-filled URL under what browsers and GitHub accept.
    private static let maxBodyCharacters = 5000

    private var reportedKinds: Set<String> = []
    private var panel: NSPanel?

    private init() {}

    /// Same as `report`, callable from any thread or actor.
    nonisolated static func offer(kind: String, title: String, detail: String) {
        Task { @MainActor in shared.report(kind: kind, title: title, detail: detail) }
    }

    /// Shows the prompt at most once per `kind` per app launch, so a repeating
    /// failure can never turn into a stream of popups.
    func report(kind: String, title: String, detail: String) {
        guard reportedKinds.insert(kind).inserted else { return }
        wpWarn("[ErrorReporter] offering report for \(kind): \(detail)")
        show(kind: kind, title: title, detail: detail)
    }

    private func show(kind: String, title: String, detail: String) {
        panel?.close()

        let view = ErrorReportPrompt(
            detail: detail,
            onReport: { [weak self] in
                self?.openIssue(title: title, detail: detail)
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Whisper Pilot"
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(host.view.fittingSize)
        panel.center()
        // Not made key, so it never steals focus from the meeting or overlay.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func dismiss() {
        panel?.close()
        panel = nil
    }

    private func openIssue(title: String, detail: String) {
        var components = URLComponents(string: "https://github.com/\(Self.repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: Self.issueBody(detail: detail)),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func issueBody(detail: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let recent = LogBuffer.shared.entries
            .filter { $0.level == .warn || $0.level == .error }
            .suffix(15)
            .map { "\($0.level.rawValue.uppercased()) \(String($0.message.prefix(200)))" }
            .joined(separator: "\n")
        let body = """
        Whisper Pilot noticed this problem on its own.

        **Error:** \(detail)

        **App:** \(AppInfo.version)
        **macOS:** \(os)

        <details><summary>Recent warnings and errors</summary>

        ```
        \(recent)
        ```

        </details>
        """
        return String(body.prefix(maxBodyCharacters))
    }
}

private struct ErrorReportPrompt: View {
    let detail: String
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("We noticed an error")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Want to report it on GitHub? This opens a pre-filled issue in your browser. Nothing is sent until you submit it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now", action: onDismiss)
                Button("Report on GitHub", action: onReport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
