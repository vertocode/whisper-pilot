import AVFoundation
import Foundation
import OSLog

/// Microphone capture via AVAudioEngine. Output is converted to the canonical 16 kHz mono format.
final class MicrophoneCapture {
    let frames: AsyncStream<AudioFrame>
    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "Microphone")

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init() {
        var capturedContinuation: AsyncStream<AudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func start() async throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MicrophoneError.invalidFormat
        }
        sourceFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make())

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        try engine.start()
        log.info("Microphone capture started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        sourceFormat = nil
    }

    deinit {
        continuation.finish()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let outputFormat = CanonicalAudioFormat.make()
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("Mic conversion error: \(String(describing: error), privacy: .public)")
            return
        }
        continuation.yield(AudioFrame(buffer: output, channel: .microphone, timestamp: Date()))
    }
}

enum MicrophoneError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Microphone returned an invalid audio format."
        }
    }
}
