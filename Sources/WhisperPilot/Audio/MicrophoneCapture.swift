import AVFoundation
import CoreAudio
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
    private var framesEmitted: Int = 0

    init() {
        var capturedContinuation: AsyncStream<AudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func start() async throws {
        log.info("Starting microphone capture…")
        // Log the active default input device so the user can see in Diagnostics whether
        // macOS routed us to the right microphone (built-in vs USB vs Bluetooth, etc.).
        if let info = Self.defaultInputDeviceInfo() {
            wpInfo("Microphone default input device: \(info.name ?? "unknown") (id=\(info.id))")
        } else {
            wpWarn("Couldn't read default input device — Core Audio query failed")
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            log.error("Microphone returned invalid format (sampleRate=0)")
            throw MicrophoneError.invalidFormat
        }
        sourceFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make())

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        try engine.start()
        log.info("✓ Microphone capture started at \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch")
        print("[WP][Microphone] started @ \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        sourceFormat = nil
        log.info("Microphone capture stopped after \(self.framesEmitted, privacy: .public) frames")
        framesEmitted = 0
    }

    deinit {
        continuation.finish()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let outputFormat = CanonicalAudioFormat.make()
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        // Reset before each conversion — without this the converter enters a terminal
        // "stream ended" state after the first endOfStream and produces 0 frames forever.
        converter.reset()
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("Mic conversion error: \(String(describing: error), privacy: .public)")
            return
        }
        framesEmitted += 1
        if framesEmitted < 5 || framesEmitted % 200 == 0 {
            let inRMS = Self.computeRMSAny(buffer)
            let outRMS = Self.computeRMSAny(output)
            wpInfo("Microphone frame#\(framesEmitted) inFrames=\(buffer.frameLength) outFrames=\(output.frameLength) inRMS=\(String(format: "%.5f", inRMS)) outRMS=\(String(format: "%.5f", outRMS))")
        }
        continuation.yield(AudioFrame(buffer: output, channel: .microphone, timestamp: Date()))
    }

    /// Reads `kAudioHardwarePropertyDefaultInputDevice` and that device's display name.
    /// We use this purely to log what the user is currently set to — picking a device
    /// programmatically through AVAudioEngine is more involved and not yet exposed.
    static func defaultInputDeviceInfo() -> (id: AudioObjectID, name: String?)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard getDeviceStatus == noErr, deviceID != 0 else { return nil }

        address.mSelector = kAudioObjectPropertyName
        var name: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return (deviceID, nameStatus == noErr ? (name as String?) : nil)
    }

    static func defaultOutputDeviceInfo() -> (id: AudioObjectID, name: String?)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard getDeviceStatus == noErr, deviceID != 0 else { return nil }

        address.mSelector = kAudioObjectPropertyName
        var name: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return (deviceID, nameStatus == noErr ? (name as String?) : nil)
    }

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

enum MicrophoneError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Microphone returned an invalid audio format."
        }
    }
}
