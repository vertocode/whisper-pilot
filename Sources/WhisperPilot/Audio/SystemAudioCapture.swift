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
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make())
            wpInfo("System audio source format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, interleaved=\(inputFormat.isInterleaved), commonFormat=\(inputFormat.commonFormat.rawValue)")
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

        let outputFormat = CanonicalAudioFormat.make()
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * outputFormat.sampleRate / inputFormat.sampleRate) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let error {
            log.error("Conversion error: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Multi-stage RMS so we can tell whether the source is silent or our converter is.
        if framesEmitted < 5 || framesEmitted % 200 == 0 {
            let inRMS = Self.computeRMSAny(inputBuffer)
            let outRMS = Self.computeRMSAny(outputBuffer)
            wpInfo("SystemAudio frame#\(framesEmitted) inFrames=\(inputBuffer.frameLength) outFrames=\(outputBuffer.frameLength) inRMS=\(String(format: "%.5f", inRMS)) outRMS=\(String(format: "%.5f", outRMS))")
        }

        return outputBuffer
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
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(String(describing: error), privacy: .public)")
        print("[WP][SystemAudio] SCStream stopped with error: \(error.localizedDescription)")
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
