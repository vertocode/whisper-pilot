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
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        wpInfo("ProcessAudio: tap format \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, formatID=0x\(String(asbd.mFormatID, radix: 16)), bitsPerChannel=\(asbd.mBitsPerChannel), bytesPerFrame=\(asbd.mBytesPerFrame), isFloat=\(isFloat), nonInterleaved=\(isNonInterleaved)")

        var asbdCopy = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &asbdCopy) else {
            throw ProcessAudioError.formatConversionFailed
        }
        self.inputFormat = inputFormat
        wpInfo("ProcessAudio: AVAudioFormat resolved — sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), interleaved=\(inputFormat.isInterleaved), commonFormat=\(inputFormat.commonFormat.rawValue)")
        self.converter = AVAudioConverter(from: inputFormat, to: CanonicalAudioFormat.make())

        // 4. Create a private aggregate device backed by the tap.
        // CRITICAL: anchor the aggregate to the system's default output device via
        // `kAudioAggregateDeviceMainSubDeviceKey`. Without it, the aggregate has no clock
        // source and the tap delivers silent buffers — that's exactly the symptom we hit:
        // RMS=0 across thousands of frames despite Chrome playing audio.
        // Apple's WWDC 2024 reference sample shows this is required.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = 0
            throw ProcessAudioError.outputDeviceUnavailable
        }
        wpInfo("ProcessAudio: anchoring aggregate to output device UID=\(outputUID)")

        let aggregateUID = "com.whisperpilot.app.aggregate.\(UUID().uuidString)"
        // The output device must be present in BOTH `MainSubDeviceKey` AND
        // `SubDeviceListKey`. The tap by itself doesn't run a clock — it needs to be
        // attached to a real device that's producing audio. Apple's WWDC24 reference
        // and `AudioCap` both include both keys; missing `SubDeviceListKey` was why
        // the tap was still silent on this user's machine.
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Whisper Pilot Aggregate",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID as String]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: uuid as String,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
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

        // Compute RMS directly from the AudioBufferList memory before any
        // AVAudioPCMBuffer wrapping. Useful as ground truth.
        let rawRMS = framesEmitted < 5 ? Self.rawFloat32RMS(bufferList) : -1

        // Read frame count from the bufferList directly. We deliberately do NOT use
        // `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` here — the converter was unable
        // to consume the wrapped buffer correctly and produced 0 output frames despite
        // valid input (confirmed by `inRMS=0.01 outRMS=0` logs). Allocating a fresh
        // buffer and memcpy-ing the audio data costs ~10µs per buffer and gives us a
        // properly-formed input that the converter handles.
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }
        let bytesPerFrame = inputFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let firstByteSize = Int(abl[0].mDataByteSize)
        let frameCount = AVAudioFrameCount(firstByteSize / Int(bytesPerFrame))
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return }
        inputBuffer.frameLength = frameCount
        let dstABL = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        for i in 0..<min(abl.count, dstABL.count) {
            let src = abl[i]
            let dst = dstABL[i]
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let copyBytes = min(Int(dst.mDataByteSize), Int(src.mDataByteSize))
            memcpy(dstData, srcData, copyBytes)
        }

        let outputFormat = CanonicalAudioFormat.make()
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * outputFormat.sampleRate / inputFormat.sampleRate) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        // CRITICAL: reset the converter before each call. Without this, AVAudioConverter
        // enters a "stream ended" state after the first `endOfStream` signal and produces
        // 0 output frames for every subsequent convert(). Verified by synthetic test:
        // without reset, calls 2..N return 0 frames. With reset, all calls work.
        converter.reset()
        var convertError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &convertError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let convertError {
            wpError("ProcessAudio convert error: \(convertError.localizedDescription)")
            return
        }

        // Apply 5× gain to system audio. The macOS audio mixdown that Process Tap
        // captures is typically much quieter than microphone input — usually below
        // SFSpeech's internal speech-detection threshold (verified: live RMS ≈ 0.0067
        // vs typical mic speech RMS ≈ 0.05). Boosting the signal so the recognizer
        // actually treats it as speech.
        if let outputData = outputBuffer.floatChannelData {
            let gain: Float = 5.0
            let frames = Int(outputBuffer.frameLength)
            let channels = Int(outputBuffer.format.channelCount)
            for c in 0..<channels {
                let ptr = outputData[c]
                for i in 0..<frames {
                    let amplified = ptr[i] * gain
                    // Clamp to [-1, 1] to avoid wraparound distortion on transients.
                    ptr[i] = max(-1.0, min(1.0, amplified))
                }
            }
        }

        framesEmitted += 1
        if framesEmitted < 5 || framesEmitted % 200 == 0 {
            let inRMS = Self.computeRMSAny(inputBuffer)
            let outRMS = Self.computeRMSAny(outputBuffer)
            let rawTag = rawRMS >= 0 ? " rawRMS=\(String(format: "%.5f", rawRMS))" : ""
            wpInfo("ProcessAudio frame#\(framesEmitted) inFrames=\(frameCount) outFrames=\(outputBuffer.frameLength) inRMS=\(String(format: "%.5f", inRMS)) outRMS=\(String(format: "%.5f", outRMS))\(rawTag)")
        }

        let frame = AudioFrame(buffer: outputBuffer, channel: .system, timestamp: Date())
        continuation.yield(frame)
    }

    /// RMS computed directly off the AudioBufferList memory, treating it as Float32. This
    /// bypasses AVAudioPCMBuffer wrapping entirely — useful as ground truth for whether
    /// the source is silent or our wrapping is misinterpreting layout.
    private static func rawFloat32RMS(_ bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var sum: Double = 0
        var count: Int = 0
        for i in 0..<abl.count {
            let buf = abl[i]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.assumingMemoryBound(to: Float.self)
            for j in 0..<frameCount {
                let s = Double(ptr[j])
                sum += s * s
            }
            count += frameCount
        }
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
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

    /// Reads the system-default output device's UID. Required by `CATapDescription`
    /// aggregate setups so the tap has a clock source — without anchoring to an actual
    /// output device, the tap silently produces empty buffers.
    private static func defaultOutputDeviceUID() -> CFString? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let getDevice = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard getDevice == noErr, deviceID != 0 else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let getUID = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return getUID == noErr ? uid : nil
    }

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
    case outputDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .tapCreateFailed(let s): return "Couldn't create Core Audio process tap (status=\(s))."
        case .aggregateCreateFailed(let s): return "Couldn't create aggregate device (status=\(s))."
        case .procCreateFailed(let s): return "Couldn't register audio IO callback (status=\(s))."
        case .deviceStartFailed(let s): return "Couldn't start audio device (status=\(s))."
        case .formatConversionFailed: return "Couldn't translate Core Audio stream format to AVAudioFormat."
        case .propertyReadFailed(let selector, let s): return "Couldn't read Core Audio property 0x\(String(selector, radix: 16)) (status=\(s))."
        case .outputDeviceUnavailable: return "Couldn't read default output device — Process Tap needs an output to anchor to."
        }
    }
}
