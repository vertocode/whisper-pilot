import SwiftUI

struct TranscriptLane: View {
    /// Upper bound on rows rendered in the lane. Long sessions accumulate
    /// thousands of segments; the view only ever shows the recent window.
    static let maxRenderedSegments = 150

    let segments: [TranscriptSegment]
    /// When true, only the header row is rendered (chevron flips to indicate
    /// expand). The body — segment list / "waiting for audio" placeholder — is
    /// omitted so the lane collapses to one tappable bar.
    var isCollapsed: Bool = false
    /// When false, suppresses the header row so only segment content renders.
    /// Used when the caller pins the header outside a ScrollView.
    var showHeader: Bool = true
    /// When false, suppresses segment content so only the header row renders.
    /// Used to create a sticky header above a ScrollView.
    var showContent: Bool = true
    /// Invoked when the user taps the chevron in the header. The owner toggles
    /// the bound state; this lane just renders accordingly.
    var onToggleCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            if showHeader {
                HStack(spacing: WP.Space.sm) {
                    // The title itself is a click target for collapse/expand —
                    // bigger and more discoverable than the pill alone.
                    HStack(spacing: WP.Space.sm) {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Live transcript")
                            .font(WP.TextStyle.sectionHeader)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleCollapse?() }
                    Spacer()
                    if !segments.isEmpty {
                        Text("\(segments.count) line\(segments.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    if let onToggleCollapse {
                        CollapseToggle(isCollapsed: isCollapsed, action: onToggleCollapse)
                            .help(isCollapsed ? "Show transcript" : "Hide transcript")
                    }
                }
            }

            if !isCollapsed && showContent {
                if segments.isEmpty {
                    HStack(spacing: WP.Space.sm) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text("Waiting for audio…")
                            .font(WP.TextStyle.body)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WP.Space.md - 2)
                    .padding(.vertical, WP.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: WP.Radius.lg, style: .continuous)
                            .fill(.quinary)
                    )
                } else {
                    // Render only the most recent window. Each utterance is its own
                    // row (VAD-driven); the parent ScrollView in OverlayView handles
                    // overflow, and explicit `.id()` lets the parent's
                    // ScrollViewReader auto-scroll to the most recent line as it
                    // arrives. Rendering the full history made every 250 ms publish
                    // re-diff a lane that grows without bound in long sessions —
                    // the full transcript is always on disk in transcript.md.
                    LazyVStack(alignment: .leading, spacing: WP.Space.xs + 2) {
                        if segments.count > Self.maxRenderedSegments {
                            Text("… earlier transcript trimmed from view (full history is in the session's transcript.md)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, WP.Space.md - 2)
                        }
                        ForEach(segments.suffix(Self.maxRenderedSegments)) { segment in
                            TranscriptRow(segment: segment)
                                .id(segment.id)
                        }
                    }
                }
            }
        }
    }
}

/// Shared collapse/expand control used by both lane headers. A labeled
/// Show/Hide pill instead of a bare chevron — the chevron read as a generic
/// dropdown and users didn't connect it to "collapse this section". Lives here
/// (rather than in OverlayView) so both `TranscriptLane` and `ChatLane` can
/// reuse it without re-implementing the styling and tap target.
struct CollapseToggle: View {
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isCollapsed ? "eye" : "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text(isCollapsed ? "Show" : "Hide")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quinary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    /// User-chosen overlay text color (nil = system default). Only applied to
    /// finalized lines; in-progress (volatile) text stays muted secondary so the
    /// user can tell committed text from a hypothesis being refined.
    @Environment(\.overlayTextColor) private var overlayTextColor

    var body: some View {
        HStack(alignment: .top, spacing: WP.Space.sm) {
            Text(label)
                .font(WP.TextStyle.tag)
                .chip(.channel(color), horizontalPadding: 6, verticalPadding: 2)
                .frame(minWidth: 44, alignment: .leading)
            Text(segment.text)
                .font(WP.TextStyle.body)
                .foregroundStyle(segment.isFinal ? AnyShapeStyle(overlayTextColor ?? .primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 1)
        }
    }

    private var label: String {
        segment.channel == .system ? "OTHER" : "ME"
    }

    private var color: Color {
        segment.channel == .system ? .blue : .purple
    }
}
