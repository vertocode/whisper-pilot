import Darwin
import Dispatch
import Foundation

/// The limits that end the app on purpose. They sit above everything `ResourceGovernor`
/// does, and they are the same on every Mac.
struct HardCeilingConfig: Sendable, Equatable {
    /// Memory footprint (`phys_footprint`) the app may never stay above.
    var footprintBytes: UInt64
    /// A short spike above the footprint is fine (model loading); this long is not.
    var footprintSustainSeconds: TimeInterval
    /// CPU level (100 = one core) the app may not hold for `cpuSustainSeconds`.
    var cpuPercent: Double
    var cpuSustainSeconds: TimeInterval
    /// Short dips below the CPU level do not restart the CPU clock.
    var cpuDipToleranceSeconds: TimeInterval

    static let `default` = HardCeilingConfig(
        footprintBytes: 2_250_000_000,
        footprintSustainSeconds: 3,
        cpuPercent: 300,
        cpuSustainSeconds: 60,
        cpuDipToleranceSeconds: 2
    )
}

enum HardCeilingReason: String, Sendable, Equatable {
    case memory
    case cpu

    var label: String {
        switch self {
        case .memory: return "memory"
        case .cpu: return "CPU"
        }
    }
}

/// Pure decision logic for the hard ceiling: feed it samples with a non-decreasing clock.
struct HardCeiling: Sendable {
    private let config: HardCeilingConfig
    private var memoryOverSince: TimeInterval?
    private var cpuOverSince: TimeInterval?
    private var lastCPUOverAt: TimeInterval?

    init(config: HardCeilingConfig = .default) {
        self.config = config
    }

    /// Returns the reason to shut down, or nil while everything is under the ceiling.
    mutating func evaluate(_ sample: ResourceSample, at now: TimeInterval) -> HardCeilingReason? {
        if sample.memoryBytes > config.footprintBytes {
            if memoryOverSince == nil { memoryOverSince = now }
            if let since = memoryOverSince, now - since >= config.footprintSustainSeconds { return .memory }
        } else {
            memoryOverSince = nil
        }

        if sample.cpuPercent > config.cpuPercent {
            if cpuOverSince == nil { cpuOverSince = now }
            lastCPUOverAt = now
            if let since = cpuOverSince, now - since >= config.cpuSustainSeconds { return .cpu }
        } else if let last = lastCPUOverAt, now - last > config.cpuDipToleranceSeconds {
            cpuOverSince = nil
            lastCPUOverAt = nil
        }
        return nil
    }
}

/// Watches the app's own memory and CPU from a plain background queue, so it keeps working
/// when the main thread is stuck (the soft valve in `AppCoordinator` cannot). When a ceiling
/// is crossed it calls `onTrip` once. If the app is still alive `exitDeadlineSeconds` later,
/// it ends the process, so a hung shutdown can never leave the Mac frozen.
final class HardCeilingMonitor: @unchecked Sendable {
    static let exitDeadlineSeconds: TimeInterval = 12

    private let sampler: ResourceSampling
    private let queue = DispatchQueue(label: "com.whisperpilot.hard-ceiling", qos: .userInitiated)
    private let onTrip: @Sendable (HardCeilingReason, ResourceSample) -> Void
    private var ceiling: HardCeiling
    private var timer: DispatchSourceTimer?
    private var tripped = false

    init(
        config: HardCeilingConfig = .default,
        sampler: ResourceSampling = ResourceSampler(),
        onTrip: @escaping @Sendable (HardCeilingReason, ResourceSample) -> Void
    ) {
        self.ceiling = HardCeiling(config: config)
        self.sampler = sampler
        self.onTrip = onTrip
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [self] in tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard !tripped else { return }
        let sample = sampler.sample()
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard let reason = ceiling.evaluate(sample, at: now) else { return }
        tripped = true
        queue.asyncAfter(deadline: .now() + Self.exitDeadlineSeconds) { _exit(1) }
        onTrip(reason, sample)
    }
}
