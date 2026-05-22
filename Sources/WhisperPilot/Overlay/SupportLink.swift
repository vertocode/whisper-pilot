import SwiftUI

/// Subtle "Buy me a coffee" link that deep-links into vertocode.com's
/// donation modal via the `?coffee=true` query param so the user lands
/// directly on the form rather than the footer of the portfolio site.
///
/// Reused from three surfaces — the overlay footer, the Sessions home page
/// header, and the Settings header — so style + copy + target URL stay in
/// one place. Two variants: `.compact` for tight horizontal real estate (the
/// overlay composer row), `.expanded` where there's room for a full label.
struct SupportLink: View {
    enum Style {
        case compact
        case expanded
    }

    let style: Style

    private static let url = URL(string: "https://vertocode.com/?coffee=true")!

    var body: some View {
        Link(destination: Self.url) {
            HStack(spacing: 4) {
                Text("☕")
                    .font(.system(size: 11))
                if style == .expanded {
                    Text("Buy me a coffee")
                        .font(WP.TextStyle.micro)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Support Whisper Pilot's development — opens a donation page in your browser. Bring-your-own-API-key tools don't make money on their own; tips help cover the time.")
    }
}
