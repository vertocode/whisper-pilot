import AVFoundation
import Foundation

/// Energy-threshold VAD. Cheap, good enough for "is someone talking right now".
/// Real diarization / speaker-aware VAD is in the roadmap; the protocol here is small
/// so a smarter implementation slots in cleanly.
enum VoiceActivityEvent: Sendable {
    case speechStarted(channel: AudioChannel, at: Date)
    case speechEnded(channel: AudioChannel, at: Date, duration: TimeInterval, silenceLeading: TimeInterval)
}

actor VoiceActivityDetector {
    private struct ChannelState {
        var isSpeaking = false
        var startedAt: Date?
        var lastVoiceAt: Date?
        var lastSilenceStart: Date?
    }

    private let threshold: Float = 0.0025
    private let hangoverSeconds: TimeInterval = 0.4

    private var states: [AudioChannel: ChannelState] = [:]

    /// Drop all per-channel state — used when the pipeline restarts so a half-finished
    /// utterance from the previous session doesn't poison the new session's first
    /// frames (which would otherwise be silently classified as "still speaking" and
    /// never emit a `.speechStarted` event until silence broke the spell).
    func reset() {
        states.removeAll()
    }

    func feed(_ frame: AudioFrame) -> VoiceActivityEvent? {
        let rms = computeRMS(frame.buffer)
        var state = states[frame.channel] ?? ChannelState()
        defer { states[frame.channel] = state }

        let voiced = rms > threshold
        let now = frame.timestamp

        if voiced {
            state.lastVoiceAt = now
            if !state.isSpeaking {
                state.isSpeaking = true
                state.startedAt = now
                state.lastSilenceStart = nil
                return .speechStarted(channel: frame.channel, at: now)
            }
            return nil
        }

        if state.isSpeaking {
            state.lastSilenceStart = state.lastSilenceStart ?? now
            if let silenceStart = state.lastSilenceStart,
               now.timeIntervalSince(silenceStart) >= hangoverSeconds,
               let started = state.startedAt {
                state.isSpeaking = false
                let duration = now.timeIntervalSince(started)
                state.startedAt = nil
                let leading = now.timeIntervalSince(silenceStart)
                return .speechEnded(channel: frame.channel, at: now, duration: duration, silenceLeading: leading)
            }
        }
        return nil
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let pointer = channelData.pointee
        var sum: Float = 0
        for i in 0..<frames {
            let sample = pointer[i]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
    }
}
