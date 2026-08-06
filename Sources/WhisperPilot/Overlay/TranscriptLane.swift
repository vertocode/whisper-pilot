import SwiftUI

/// Carries the lane's rendered width up from a zero-cost background reader.
/// Used to decide side-by-side vs stacked without wrapping rows in
/// `GeometryReader`s, which inside a `LazyVStack` would fight the intrinsic
/// height every row needs.
private struct LaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranscriptLane: View {
    /// Upper bound on rows rendered in the lane. Long sessions accumulate
    /// thousands of segments; the view only ever shows the recent window.
    static let maxRenderedSegments = 150

    /// Horizontal budget a row spends before its text starts: the channel chip's
    /// `minWidth` plus the `HStack` spacing next to it. Subtracted from the
    /// measured lane width so the layout decision is made on the width text
    /// actually gets, not the width the lane occupies.
    private static let chipGutter: CGFloat = 44 + WP.Space.sm

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

    /// Latest measured lane width. Only meaningful once a layout pass has run;
    /// starts at zero, which resolves `.auto` to stacked until measured.
    @State private var laneWidth: CGFloat = 0

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
                            TranscriptRow(
                                segment: segment,
                                textWidth: max(0, laneWidth - Self.chipGutter)
                            )
                            .id(segment.id)
                        }
                    }
                }
            }
        }
        // Zero-cost width probe: a clear background never affects layout, so
        // measuring here can't perturb the row heights it informs.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: LaneWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(LaneWidthKey.self) { width in
            // Ignore sub-point jitter from the divider drag so a resize doesn't
            // thrash `.auto` back and forth across the threshold.
            if abs(width - laneWidth) > 1 { laneWidth = width }
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
    /// Width available to text after the channel chip, measured by the lane.
    /// Drives `.auto`'s side-by-side / stacked choice and the 45/55 split.
    /// Zero until the first layout pass, which resolves to stacked — the safe
    /// direction, since stacked is readable at any width.
    var textWidth: CGFloat = 0
    /// User-chosen overlay text color (nil = system default). Only applied to
    /// finalized lines; in-progress (volatile) text stays muted secondary so the
    /// user can tell committed text from a hypothesis being refined.
    @Environment(\.overlayTextColor) private var overlayTextColor
    /// nil = translations not rendered (feature off, or nothing configured).
    @Environment(\.translationLayout) private var translationLayout

    var body: some View {
        HStack(alignment: .top, spacing: WP.Space.sm) {
            Text(label)
                .font(WP.TextStyle.tag)
                .chip(.channel(color), horizontalPadding: 6, verticalPadding: 2)
                .frame(minWidth: 44, alignment: .leading)
            content
        }
    }

    /// Rows without a translation — every microphone row, plus any system row
    /// whose translation hasn't landed yet — render exactly as they did before
    /// the feature existed. That's what makes "translation off" genuinely free
    /// rather than merely cheap.
    @ViewBuilder
    private var content: some View {
        if let translated = segment.translatedText,
           let layout = translationLayout,
           !translated.isEmpty {
            switch layout.resolved(forTextWidth: textWidth) {
            case .sideBySide:
                HStack(alignment: .top, spacing: WP.Space.sm) {
                    sourceText
                        .frame(width: max(60, textWidth * TranslationLayout.sourceWidthFraction),
                               alignment: .leading)
                    translationText(translated)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .stacked, .auto:
                VStack(alignment: .leading, spacing: 1) {
                    sourceText
                    translationText(translated)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            sourceText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceText: some View {
        Text(segment.text)
            .font(WP.TextStyle.body)
            .foregroundStyle(segment.isFinal ? AnyShapeStyle(overlayTextColor ?? .primary) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .padding(.top, 1)
    }

    /// Rendered a step down from the source so a glance can tell which column
    /// is the original. Kept selectable — copying a translated line out of a
    /// meeting is a real use.
    private func translationText(_ translated: String) -> some View {
        Text(translated)
            .font(WP.TextStyle.body)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 1)
    }

    private var label: String {
        segment.channel == .system ? "OTHER" : "ME"
    }

    private var color: Color {
        segment.channel == .system ? .blue : .purple
    }
}
