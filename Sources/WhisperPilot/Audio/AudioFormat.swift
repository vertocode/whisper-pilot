import AVFoundation

enum AudioChannel: Sendable, Hashable {
    case system
    case microphone
}

struct AudioFrame: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let channel: AudioChannel
    let timestamp: Date
}

enum CanonicalAudioFormat {
    static let sampleRate: Double = 16_000

    static func make() -> AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
    }

    static func converter(from source: AVAudioFormat) -> AVAudioConverter? {
        AVAudioConverter(from: source, to: make())
    }
}
