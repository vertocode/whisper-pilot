import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

/// Captures system audio (everything macOS is playing) via ScreenCaptureKit.
/// We don't capture video — `SCStreamConfiguration.capturesAudio = true` with `excludesCurrentProcessAudio = true`.
/// Frames are converted to the canonical 16 kHz mono PCM format consumed by the rest of the pipeline.
final class SystemAudioCapture: NSObject {
    let frames: AsyncStream<AudioFrame>

    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "SystemAudio")
    private let queue = DispatchQueue(label: "com.whisperpilot.system-audio", qos: .userInitiated)

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    override init() {
        var capturedContinuation: AsyncStream<AudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(CanonicalAudioFormat.sampleRate)
        config.channelCount = 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("System audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        do { try await stream.stopCapture() } catch {
            log.error("Stop error: \(String(describing: error), privacy: .public)")
        }
        self.stream = nil
        self.converter = nil
        self.sourceFormat = nil
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
        log.error("SCStream stopped: \(String(describing: error), privacy: .public)")
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
