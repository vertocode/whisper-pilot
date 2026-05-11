import SwiftUI

struct TranscriptLane: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            HStack(spacing: WP.Space.sm) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Live transcript")
                    .font(WP.TextStyle.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                if !segments.isEmpty {
                    Text("\(segments.count) line\(segments.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

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
                // Show every segment. Each utterance is its own row (VAD-driven). The
                // parent ScrollView in OverlayView handles overflow. Explicit `.id()`
                // lets the parent's ScrollViewReader auto-scroll to the most recent
                // line as it arrives, regardless of which channel produced it.
                VStack(alignment: .leading, spacing: WP.Space.xs + 2) {
                    ForEach(segments) { segment in
                        TranscriptRow(segment: segment)
                            .id(segment.id)
                    }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: WP.Space.sm) {
            Text(label)
                .font(WP.TextStyle.tag)
                .chip(.channel(color), horizontalPadding: 6, verticalPadding: 2)
                .frame(minWidth: 44, alignment: .leading)
            Text(segment.text)
                .font(WP.TextStyle.body)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
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
