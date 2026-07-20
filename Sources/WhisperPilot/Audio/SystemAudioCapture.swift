import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

/// Captures system audio (everything macOS is playing) via ScreenCaptureKit.
/// Frames are converted to the canonical 16 kHz mono PCM format consumed by the rest of the pipeline.
final class SystemAudioCapture: NSObject {
    let frames: AsyncStream<AudioFrame>

    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "SystemAudio")
    private let queue = DispatchQueue(label: "com.whisperpilot.system-audio", qos: .userInitiated)

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var framesEmitted: Int = 0
    /// True between `stop()` and the next `start()`. Lets the delegate's
    /// crash-restart loop tell a deliberate teardown apart from a mid-session
    /// stream failure.
    private var manuallyStopped = false

    override init() {
        var capturedContinuation: AsyncStream<AudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        super.init()
    }

    func start() async throws {
        log.info("Starting system audio capture…")
        print("[WP][SystemAudio] start() begin")
        manuallyStopped = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            log.error("No display available for capture")
            throw SystemAudioError.noDisplay
        }
        log.info("Using display \(display.displayID, privacy: .public) (\(display.width)x\(display.height))")
        print("[WP][SystemAudio] using display \(display.displayID) \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Pin the audio config explicitly. Letting these default has been observed to
        // produce empty audio buffers (RMS = 0) on some macOS Sonoma/Sequoia configurations.
        config.sampleRate = 48000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Tiny dummy video size — we don't consume video, but ScreenCaptureKit requires a
        // sane non-zero rect. 100x100 is empirically more reliable than 2x2 on Sonoma+.
        config.width = 100
        config.height = 100
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("✓ System audio capture started; awaiting frames")
        print("[WP][SystemAudio] startCapture returned; awaiting frames")
    }

    func stop() async {
        manuallyStopped = true
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            log.info("System audio capture stopped after \(self.framesEmitted, privacy: .public) frames")
        } catch {
            log.error("Stop error: \(String(describing: error), privacy: .public)")
        }
        self.stream = nil
        self.converter = nil
        self.sourceFormat = nil
        self.framesEmitted = 0
    }

    deinit {
        continuation.finish()
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Count delegate invocations regardless of type so we can tell if SCStream is
        // delivering ANYTHING. If this never fires, the stream itself isn't producing.
        if framesEmitted == 0 {
            print("[WP][SystemAudio] didOutputSampleBuffer fired (type=\(type.rawValue), valid=\(sampleBuffer.isValid))")
        }
        guard type == .audio else { return }
        guard sampleBuffer.isValid else {
            print("[WP][SystemAudio] received invalid audio sample buffer")
            return
        }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else {
            if framesEmitted == 0 {
                print("[WP][SystemAudio] makePCMBuffer returned nil for first sample")
            }
            return
        }

        let frame = AudioFrame(buffer: pcm, channel: .system, timestamp: Date())
        framesEmitted += 1
        if framesEmitted == 1 {
            log.info("First system audio frame received (sampleRate=\(pcm.format.sampleRate), channels=\(pcm.format.channelCount), frameLength=\(pcm.frameLength))")
            print("[WP][SystemAudio] FIRST frame received sampleRate=\(pcm.format.sampleRate) frames=\(pcm.frameLength)")
        } else if framesEmitted % 200 == 0 {
            print("[WP][SystemAudio] frames emitted: \(framesEmitted)")
        }
        continuation.yield(frame)
    }

    private func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sample.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription else { return nil }
        var streamDescription = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        if sourceFormat?.isEqual(inputFormat) != true {
            if let newConverter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make()) {
                sourceFormat = inputFormat
                converter = newConverter
                wpInfo("System audio source format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, interleaved=\(inputFormat.isInterleaved), commonFormat=\(inputFormat.commonFormat.rawValue)")
            } else {
                // Do NOT record the new format on failure — doing so would make
                // the next buffer compare equal, skip this branch forever, and
                // leave the channel permanently dead on a stale nil converter.
                sourceFormat = nil
                converter = nil
                wpError("System audio: no converter for source format \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch — will retry on next buffer")
            }
        }
        guard let converter else { return nil }

        let frameCount = AVAudioFrameCount(sample.numSamples)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return nil
        }
        inputBuffer.frameLength = frameCount

        do {
            try sample.copyPCMData(
                fromRange: 0..<Int(frameCount),
                into: inputBuffer.mutableAudioBufferList
            )
        } catch {
            log.error("Sample copy failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Streaming conversion — no per-buffer reset, so the resampler's filter
        // state carries across buffers. See `StreamingAudioConverter`.
        guard let outputBuffer = StreamingAudioConverter.convert(inputBuffer, using: converter, label: "SystemAudio") else {
            return nil
        }

        // Apply gain to match the level the ProcessAudioCapture path produces.
        // The macOS mixdown SCK delivers sits just above the speech recognizer's
        // internal speech-detection floor; word-by-word the level dips below that
        // floor and the recognizer commits each word as its own utterance, which
        // showed up as a transcript fragmented one-word-per-line. Boosting the
        // signal keeps inter-word level above the threshold so phrases stay
        // grouped.
        Self.applyGainInPlace(outputBuffer, gain: Self.systemAudioGain)

        // Multi-stage RMS so we can tell whether the source is silent or our converter is.
        if framesEmitted < 5 || framesEmitted % 200 == 0 {
            let inRMS = Self.computeRMSAny(inputBuffer)
            let outRMS = Self.computeRMSAny(outputBuffer)
            wpInfo("SystemAudio frame#\(framesEmitted) inFrames=\(inputBuffer.frameLength) outFrames=\(outputBuffer.frameLength) inRMS=\(String(format: "%.5f", inRMS)) outRMS=\(String(format: "%.5f", outRMS))")
        }

        return outputBuffer
    }

    /// Gain factor applied to every SCK system-audio buffer. Tuned empirically to
    /// match the level produced by the Process Tap path (`ProcessAudioCapture` uses
    /// the same constant) — keeps inter-word audio above the recognizer's internal
    /// speech-detection floor so phrases stay grouped instead of fragmenting into
    /// one-word-per-line transcript output.
    static let systemAudioGain: Float = 5.0

    /// Onset of the soft-limiter knee: samples whose post-gain magnitude stays at
    /// or below this pass through linearly; above it they're compressed smoothly
    /// toward ±1 instead of being clipped flat.
    static let softLimitKnee: Float = 0.8

    /// Multiplies every float sample in `buffer` by `gain` and soft-limits the
    /// result into `[-1, 1]`. The previous hard clamp flattened every loud
    /// transient into a square wave — audible distortion that degraded speech
    /// recognition on loud system audio ("garbled words"). A soft knee keeps
    /// quiet-to-moderate samples bit-identical (full intelligibility) and bends
    /// only the loud tail asymptotically toward ±1. No-op for non-float buffers —
    /// our canonical format is always Float32 so this only runs the fast path in
    /// practice. Internal-visible so the gain contract can be pinned by the
    /// smoke-test suite.
    static func applyGainInPlace(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard let outputData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            let ptr = outputData[c]
            for i in 0..<frames {
                ptr[i] = softLimit(ptr[i] * gain)
            }
        }
    }

    /// Linear below `softLimitKnee`, then a tanh segment that approaches ±1
    /// asymptotically. Continuous and monotonic across the knee.
    static func softLimit(_ sample: Float) -> Float {
        let knee = softLimitKnee
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let headroom = 1.0 - knee
        let compressed = knee + headroom * tanhf((magnitude - knee) / headroom)
        return sample < 0 ? -compressed : compressed
    }

    /// RMS over whatever channel layout / sample format the buffer happens to use. We need
    /// a single helper that works on the CMSampleBuffer-derived input (often interleaved
    /// Float32 stereo) AND on our canonical output (non-interleaved Float32 mono).
    private static func computeRMSAny(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let floatChannelData = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            var sum: Float = 0
            var count = 0
            for c in 0..<channels {
                let ptr = floatChannelData[c]
                for i in 0..<frames {
                    let s = ptr[i]
                    sum += s * s
                    count += 1
                }
            }
            return count > 0 ? (sum / Float(count)).squareRoot() : 0
        }
        if let int16ChannelData = buffer.int16ChannelData {
            let channels = Int(buffer.format.channelCount)
            var sum: Double = 0
            var count = 0
            for c in 0..<channels {
                let ptr = int16ChannelData[c]
                for i in 0..<frames {
                    let s = Double(ptr[i]) / 32768.0
                    sum += s * s
                    count += 1
                }
            }
            return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
        }
        return 0
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    /// SCStream can die mid-session — sleep/wake, display disconnect, Screen
    /// Recording permission revoked. Logging alone leaves the system channel
    /// silently dead for the rest of the session, so attempt a few in-place
    /// restarts with backoff. `stop()` flips `manuallyStopped`, which both
    /// distinguishes deliberate teardown from failure and aborts a restart
    /// loop that's still pending when the user stops the session.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(String(describing: error), privacy: .public)")
        wpWarn("System audio stream stopped unexpectedly (\(error.localizedDescription)) — attempting restart")
        Task { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                guard !self.manuallyStopped, self.stream == nil else { return }
                do {
                    try await self.start()
                    wpInfo("System audio capture restarted after stream stop (attempt \(attempt))")
                    return
                } catch {
                    wpWarn("System audio restart attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
            wpError("System audio capture could not be restarted — the \"Other\" channel is no longer transcribing. Press Stop and Play to retry.")
        }
    }
}

enum SystemAudioError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for capture."
        }
    }
}
