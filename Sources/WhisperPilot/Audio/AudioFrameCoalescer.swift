import AVFoundation

/// Joins the small buffers capture hands us (10–40 ms) into ~100 ms ones before they
/// reach the transcriber. Each buffer costs the transcriber a lock, a stream hop and a
/// task wake-up, so fewer, larger buffers cut that overhead without changing the audio.
/// Samples are copied unchanged and in order.
struct AudioFrameCoalescer {
    let targetFrames: AVAudioFrameCount
    private var pending: AVAudioPCMBuffer?

    init(targetFrames: AVAudioFrameCount = 1_600) {
        self.targetFrames = targetFrames
    }

    /// Returns the buffers to forward now, oldest first. Empty while more audio is needed.
    /// Held audio is never dropped: if the format changes or a buffer can't be joined,
    /// the held audio comes out first, then the new buffer.
    mutating func append(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved || format.channelCount == 1,
              buffer.floatChannelData != nil else {
            return flush() + [buffer]
        }
        guard let current = pending else {
            if buffer.frameLength >= targetFrames { return [buffer] }
            return start(with: buffer)
        }
        guard current.format == format else {
            pending = nil
            if buffer.frameLength >= targetFrames { return [current, buffer] }
            return [current] + start(with: buffer)
        }

        let total = current.frameLength + buffer.frameLength
        if total > current.frameCapacity {
            guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
                pending = nil
                return [current, buffer]
            }
            Self.copy(current, into: merged, at: 0)
            Self.copy(buffer, into: merged, at: current.frameLength)
            merged.frameLength = total
            pending = nil
            return [merged]
        }
        Self.copy(buffer, into: current, at: current.frameLength)
        current.frameLength = total
        guard total >= targetFrames else { return [] }
        pending = nil
        return [current]
    }

    /// Hands back whatever is still held, e.g. when the stream ends, speech ends or the
    /// channel is muted.
    mutating func flush() -> [AVAudioPCMBuffer] {
        guard let current = pending else { return [] }
        pending = nil
        return [current]
    }

    /// Holds `buffer` for joining. Returns it straight away if a holding copy can't be made.
    private mutating func start(with buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard let merged = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: targetFrames * 2) else {
            return [buffer]
        }
        Self.copy(buffer, into: merged, at: 0)
        merged.frameLength = buffer.frameLength
        pending = merged
        return []
    }

    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, at offset: AVAudioFrameCount) {
        guard let from = source.floatChannelData, let to = destination.floatChannelData else { return }
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        for c in 0..<channels {
            (to[c] + Int(offset)).update(from: from[c], count: frames)
        }
    }
}
