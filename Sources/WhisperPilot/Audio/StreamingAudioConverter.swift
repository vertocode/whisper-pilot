import AVFoundation
import Foundation

/// Streaming-safe wrapper around `AVAudioConverter` for the capture pipeline.
///
/// History: every capture path used to call `converter.reset()` before each
/// buffer, because the input block signalled `.endOfStream` once the buffer was
/// consumed — and `.endOfStream` latches the converter into a terminal state
/// that produces 0 frames forever. The reset un-latched it, but at a brutal
/// cost for sample-rate conversion: resetting discards the resampler's filter
/// history, so every buffer lost its leading samples to re-priming and gained a
/// waveform discontinuity at the seam. With the Process Tap path's ~10 ms
/// buffers that meant ~90 glitches per second of audio handed to the speech
/// recognizer — heard as cut-off words, revised/repeated hypotheses, and
/// fragmented transcripts. ScreenCaptureKit's much larger buffers hid the same
/// bug, which is why transcripts only fell apart "when ScreenCaptureKit is
/// disabled".
///
/// The correct streaming idiom is `.noDataNow`: the converter returns whatever
/// it can produce, keeps its internal state, and the next call continues the
/// stream seamlessly. No reset, no priming loss, no seams.
enum StreamingAudioConverter {
    /// Converts one captured buffer, preserving converter state across calls.
    /// Returns nil (and logs, tagged with `label`) on conversion failure, or
    /// when the converter produced no output yet — the data isn't lost, it's
    /// buffered inside the converter and joins the next call's output.
    static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        label: String
    ) -> AVAudioPCMBuffer? {
        let outputFormat = converter.outputFormat
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                // More input wanted than we have right now. NOT `.endOfStream` —
                // that would end the converter's life; `.noDataNow` means "the
                // stream continues, next buffer arrives on the next call".
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            wpError("\(label) conversion error: \(conversionError.localizedDescription)")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}
