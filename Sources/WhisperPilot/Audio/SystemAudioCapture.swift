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
        // We deliberately leave sampleRate/channelCount at their ScreenCaptureKit defaults
        // (48 kHz stereo on most hardware) and do the resample in `makePCMBuffer` via
        // AVAudioConverter. Forcing low values here has been observed to silently produce
        // zero audio frames on some macOS versions.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Tiny dummy video size — we don't consume video, but ScreenCaptureKit requires a
        // sane non-zero rect. Apple's audio-only sample uses 2x2; we use 100x100 because
        // 2x2 has been known to silently drop audio frames on Sonoma+ on some hardware.
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
        guard type == .audio,
              sampleBuffer.isValid,
              let pcm = makePCMBuffer(from: sampleBuffer) else { return }

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
            log.info("System audio source format: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch")
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
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let error {
            log.error("Conversion error: \(String(describing: error), privacy: .public)")
            return nil
        }
        return outputBuffer
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(String(describing: error), privacy: .public)")
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
