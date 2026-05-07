import SwiftUI

struct TranscriptLane: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Live transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if segments.isEmpty {
                Text("Waiting for audio…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visible) { segment in
                    TranscriptRow(segment: segment)
                }
            }
        }
    }

    private var visible: [TranscriptSegment] {
        Array(segments.suffix(8))
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, alignment: .leading)
            Text(segment.text)
                .font(.system(size: 12))
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var label: String {
        segment.channel == .system ? "OTHER" : "ME"
    }

    private var color: Color {
        segment.channel == .system ? .blue : .purple
    }
}
