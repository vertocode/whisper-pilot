import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures system audio via Core Audio Process Taps (macOS 14.4+).
///
/// Why this instead of `SystemAudioCapture` (ScreenCaptureKit)?
/// - SCK is fundamentally a screen-capture API. Even when configured to capture only
///   audio, it triggers macOS's "screen is being recorded" state, requests Screen
///   Recording permission, and on some configurations causes audio buffers to be
///   delivered as silence (e.g., when Live Captions / aggregate devices interact with
///   the screen-share mode).
/// - Process Taps were added precisely as the audio-only alternative. They tap into a
///   process's audio output stream, deliver the buffers via a Core Audio IO callback,
///   and require neither screen recording permission nor the "screen is being recorded"
///   indicator.
///
/// The flow:
/// 1. Build a `CATapDescription` that says "capture every process except this one".
/// 2. `AudioHardwareCreateProcessTap` produces a tap object ID.
/// 3. Read the tap's UUID and stream format.
/// 4. Build a private aggregate device whose only sub-source is the tap.
/// 5. Register an IO proc on the aggregate device to receive audio callbacks.
/// 6. Start the device. Buffers arrive on a Core Audio thread; we convert to our
///    canonical 16 kHz mono format and yield to the rest of the pipeline.
@available(macOS 14.4, *)
final class ProcessAudioCapture {
    let frames: AsyncStream<AudioFrame>
    private let continuation: AsyncStream<AudioFrame>.Continuation

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var framesEmitted: Int = 0
    private let queue = DispatchQueue(label: "com.whisperpilot.process-audio", qos: .userInitiated)

    init() {
        var captured: AsyncStream<AudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func start() async throws {
        wpInfo("ProcessAudio: starting Core Audio Process Tap")

        // 1. Translate our own process ID to an audio object ID so we can exclude our
        //    own audio from the tap (avoid feedback if the app ever plays sound).
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ourProcessObject = Self.audioObjectID(forPID: ourPID)

        // Stereo global tap that captures all system audio except our own process.
        // Empty exclusion list captures everything (including our own audio, which is
        // typically silent anyway).
        let exclude: [AudioObjectID] = ourProcessObject != 0 ? [ourProcessObject] : []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.isPrivate = false
        description.name = "Whisper Pilot system tap"

        var tapID: AudioObjectID = 0
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr else {
            throw ProcessAudioError.tapCreateFailed(createStatus)
        }
        self.tapID = tapID
        wpInfo("ProcessAudio: tap created (id=\(tapID))")

        // 2. Read the tap's UUID — needed when constructing the aggregate device.
        let uuid = try Self.readCFStringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID
        )

        // 3. Read the tap's stream format — used to bridge into AVAudioFormat.
        let asbd = try Self.readASBDProperty(
            objectID: tapID,
            selector: kAudioTapPropertyFormat
        )
        wpInfo("ProcessAudio: tap format \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, formatID=0x\(String(asbd.mFormatID, radix: 16))")

        var asbdCopy = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &asbdCopy) else {
            throw ProcessAudioError.formatConversionFailed
        }
        self.inputFormat = inputFormat
        self.converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make())

        // 4. Create a private aggregate device backed by the tap.
        let aggregateUID = "com.whisperpilot.app.aggregate.\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Whisper Pilot Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: uuid as String]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]
        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = 0
            throw ProcessAudioError.aggregateCreateFailed(aggStatus)
        }
        self.aggregateID = aggregateID
        wpInfo("ProcessAudio: aggregate device created (id=\(aggregateID))")

        // 5. Register an IO proc that receives buffers on `queue`.
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock)
        guard procStatus == noErr, let procID else {
            cleanup()
            throw ProcessAudioError.procCreateFailed(procStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanup()
            throw ProcessAudioError.deviceStartFailed(startStatus)
        }

        wpInfo("ProcessAudio: ✓ started, awaiting audio buffers")
    }

    func stop() {
        cleanup()
        wpInfo("ProcessAudio: stopped after \(framesEmitted) frames")
        framesEmitted = 0
    }

    private func cleanup() {
        if let procID = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        converter = nil
        inputFormat = nil
    }

    deinit {
        cleanup()
        continuation.finish()
    }

    /// Audio IO callback. Runs on `queue` (a dedicated DispatchQueue). Wraps the raw
    /// `AudioBufferList` in an `AVAudioPCMBuffer`, runs it through our converter to the
    /// canonical 16 kHz mono format, and yields to the pipeline.
    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter else { return }
        // Wrap the in-callback AudioBufferList without copying. The pointer is only valid
        // for the duration of this callback; we use it synchronously below so that's fine.
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList) else { return }
        let frameCount = inputBuffer.frameLength
        guard frameCount > 0 else { return }

        let outputFormat = CanonicalAudioFormat.make()
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * outputFormat.sampleRate / inputFormat.sampleRate) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let error {
            wpError("ProcessAudio convert error: \(error.localizedDescription)")
            return
        }

        framesEmitted += 1
        if framesEmitted < 5 || framesEmitted % 200 == 0 {
            let inRMS = Self.computeRMSAny(inputBuffer)
            let outRMS = Self.computeRMSAny(outputBuffer)
            wpInfo("ProcessAudio frame#\(framesEmitted) inFrames=\(frameCount) outFrames=\(outputBuffer.frameLength) inRMS=\(String(format: "%.5f", inRMS)) outRMS=\(String(format: "%.5f", outRMS))")
        }

        let frame = AudioFrame(buffer: outputBuffer, channel: .system, timestamp: Date())
        continuation.yield(frame)
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

    // MARK: - Helpers

    private static func audioObjectID(forPID pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidIn = pid
        var processObject: AudioObjectID = 0
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidIn,
            &size,
            &processObject
        )
        return status == noErr ? processObject : 0
    }

    private static func readCFStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
            }
        }
        guard status == noErr, let value else {
            throw ProcessAudioError.propertyReadFailed(selector: selector, status: status)
        }
        return value
    }

    private static func readASBDProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw ProcessAudioError.propertyReadFailed(selector: selector, status: status)
        }
        return asbd
    }
}

enum ProcessAudioError: LocalizedError {
    case tapCreateFailed(OSStatus)
    case aggregateCreateFailed(OSStatus)
    case procCreateFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case formatConversionFailed
    case propertyReadFailed(selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreateFailed(let s): return "Couldn't create Core Audio process tap (status=\(s))."
        case .aggregateCreateFailed(let s): return "Couldn't create aggregate device (status=\(s))."
        case .procCreateFailed(let s): return "Couldn't register audio IO callback (status=\(s))."
        case .deviceStartFailed(let s): return "Couldn't start audio device (status=\(s))."
        case .formatConversionFailed: return "Couldn't translate Core Audio stream format to AVAudioFormat."
        case .propertyReadFailed(let selector, let s): return "Couldn't read Core Audio property 0x\(String(selector, radix: 16)) (status=\(s))."
        }
    }
}
