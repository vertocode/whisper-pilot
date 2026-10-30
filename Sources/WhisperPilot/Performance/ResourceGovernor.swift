import Foundation

/// A single resource reading handed to the governor. Produced by `ResourceSampler`
/// in production (own-process CPU, resident memory, thermal state); fabricated by
/// the smoke suite to drive the state machine deterministically.
struct ResourceSample: Sendable, Equatable {
    /// Own-process CPU usage as a percentage. Can exceed 100 on multi-core machines
    /// (one fully-pinned core ≈ 100); the governor treats it as a raw load number.
    let cpuPercent: Double
    /// Resident memory footprint of this process, in bytes.
    let memoryBytes: UInt64
    let thermalState: ProcessInfo.ThermalState
}

/// What the governor wants the app to do in response to the latest sample.
///
/// - `ok`: nothing to do — load is within budget (or recovered).
/// - `tier1Pause`: soft brake — load is high enough to back off non-essential work
///   (throttle render / pause auxiliary tasks). Core transcription keeps running.
/// - `tier2Stop`: hard stop — runaway load held for minutes, or critical thermal; the app should
///   route through its normal `stopListening` teardown.
enum ResourceDecision: Sendable, Equatable {
    case ok
    case tier1Pause
    case tier2Stop
}

/// Which signal pushed the governor into its current tier. Surfaced in logs and
/// the user-facing alert so a report says exactly what tripped.
enum ResourceTrigger: String, Sendable, Equatable {
    case cpu
    case memory
    case thermal

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "memory"
        case .thermal: return "thermal state"
        }
    }
}

/// Tunable thresholds. Kept in one struct so they can be overridden in tests and
/// adjusted later without touching the logic.
///
/// Design: on-device transcription of two channels legitimately uses more than
/// one core for a whole meeting, so a busy-but-normal session must never stop.
/// Tier-1 only sheds optional work (AI, translation rate). Tier-2 (stopping
/// listening) needs thermal `.critical`, or load far beyond normal transcription
/// cost held for minutes.
struct ResourceGovernorConfig: Sendable, Equatable {
    /// CPU percentage (100 = one core) above which the Tier-1 sustain clock runs.
    var cpuTier1Percent: Double
    /// How long CPU must stay above `cpuTier1Percent` before Tier-1 engages.
    var cpuSustainSeconds: TimeInterval
    /// Resident-memory cap; crossing it engages Tier-1 immediately (no sustain).
    var memoryTier1Bytes: UInt64
    /// Hysteresis release: Tier-1 only starts recovering once CPU is at or
    /// below this (below the engage threshold, so load oscillating around the
    /// engage point can't flap the tier on and off).
    var cpuReleasePercent: Double
    /// How long load must stay calm before Tier-1 releases back to normal.
    var recoverySeconds: TimeInterval
    /// Brief sub-threshold dips shorter than this do NOT reset a sustain run.
    var cpuDipToleranceSeconds: TimeInterval
    /// Logical core count of the machine; Tier-2 CPU scales with it.
    var coreCount: Int
    /// Tier-2 CPU level as a fraction of ALL cores (0.9 = this app alone is using
    /// 90% of the whole machine).
    var cpuTier2CoreFraction: Double
    /// How long CPU must stay above the Tier-2 level (while in Tier-1) before stopping.
    var cpuTier2SustainSeconds: TimeInterval
    /// Memory level that counts as runaway (Tier-2), as a multiple of the Tier-1 cap.
    var memoryTier2Multiplier: Double
    /// How long memory must stay above the Tier-2 level before stopping.
    var memoryTier2SustainSeconds: TimeInterval
    /// Thermal `.serious` degrades to Tier-1 right away; only if it lasts this
    /// long does it escalate to a stop. `.critical` stops immediately.
    var thermalSeriousStopSeconds: TimeInterval

    var cpuTier2Percent: Double {
        max(cpuTier1Percent * 1.5, Double(max(1, coreCount)) * 100 * cpuTier2CoreFraction)
    }

    var memoryTier2Bytes: UInt64 {
        UInt64(Double(memoryTier1Bytes) * memoryTier2Multiplier)
    }

    static let defaultCPUTier1Percent: Double = 200
    static let defaultMemoryTier1MB = 3000

    static let `default` = ResourceGovernorConfig(
        cpuTier1Percent: defaultCPUTier1Percent,
        cpuSustainSeconds: 30,
        memoryTier1Bytes: UInt64(defaultMemoryTier1MB) * 1_000_000,
        cpuReleasePercent: defaultCPUTier1Percent * 0.85,
        recoverySeconds: 5,
        cpuDipToleranceSeconds: 2,
        coreCount: ProcessInfo.processInfo.activeProcessorCount,
        cpuTier2CoreFraction: 0.9,
        cpuTier2SustainSeconds: 180,
        memoryTier2Multiplier: 2,
        memoryTier2SustainSeconds: 120,
        thermalSeriousStopSeconds: 600
    )
}

/// Pure decision module for the performance safety valve. No I/O, no sampling, no
/// timers of its own — the caller supplies each `ResourceSample` together with a
/// monotonic timestamp (seconds), so behavior is fully deterministic and testable.
///
/// State machine:
/// - **normal → tier1** when CPU stays above the threshold for `cpuSustainSeconds`,
///   when memory crosses `memoryTier1Bytes`, or on thermal `.serious`.
/// - **any → tier2** immediately on thermal `.critical`.
/// - **tier1 → tier2** when CPU stays above `cpuTier2Percent` for
///   `cpuTier2SustainSeconds`, memory stays above `memoryTier2Bytes` for
///   `memoryTier2SustainSeconds`, or thermal stays `.serious` for
///   `thermalSeriousStopSeconds`.
/// - **tier1 → normal** once load has been calm for `recoverySeconds`.
/// - **tier2** is terminal until `reset()` (the app has torn down listening).
final class ResourceGovernor {
    enum Tier: Sendable, Equatable {
        case normal
        case tier1
        case tier2
    }

    private let config: ResourceGovernorConfig
    private(set) var tier: Tier = .normal
    /// The signal behind the current tier (nil while normal).
    private(set) var trigger: ResourceTrigger?

    private var cpuOverSince: TimeInterval?
    private var lastCpuOverAt: TimeInterval?
    private var calmSince: TimeInterval?
    private var cpuTier2Since: TimeInterval?
    private var lastCpuTier2At: TimeInterval?
    private var memoryTier2Since: TimeInterval?
    private var thermalSeriousSince: TimeInterval?

    init(config: ResourceGovernorConfig = .default) {
        self.config = config
    }

    func reset() {
        tier = .normal
        trigger = nil
        cpuOverSince = nil
        lastCpuOverAt = nil
        calmSince = nil
        cpuTier2Since = nil
        lastCpuTier2At = nil
        memoryTier2Since = nil
        thermalSeriousSince = nil
    }

    /// Feed one sample taken at monotonic time `now` (seconds). `now` must be
    /// non-decreasing across calls.
    func evaluate(_ sample: ResourceSample, at now: TimeInterval) -> ResourceDecision {
        if tier == .tier2 { return .tier2Stop }

        // Only a critical thermal state stops right away; the machine is about
        // to be throttled hard and shedding optional work won't be enough.
        if sample.thermalState == .critical {
            tier = .tier2
            trigger = .thermal
            return .tier2Stop
        }

        let cpuOver = sample.cpuPercent > config.cpuTier1Percent
        if cpuOver {
            if cpuOverSince == nil { cpuOverSince = now }
            lastCpuOverAt = now
        } else if let lastOver = lastCpuOverAt, now - lastOver > config.cpuDipToleranceSeconds {
            cpuOverSince = nil
            lastCpuOverAt = nil
        }
        let cpuSustained = cpuOverSince.map { now - $0 >= config.cpuSustainSeconds } ?? false
        let memoryOver = sample.memoryBytes > config.memoryTier1Bytes
        let thermalSerious = sample.thermalState == .serious

        switch tier {
        case .tier2:
            return .tier2Stop

        case .normal:
            if thermalSerious {
                thermalSeriousSince = now
                return enterTier1(.thermal, at: now)
            }
            if memoryOver { return enterTier1(.memory, at: now) }
            if cpuSustained { return enterTier1(.cpu, at: now) }
            return .ok

        case .tier1:
            // Tier-2 clocks: each signal must be far beyond normal and stay there.
            if thermalSerious {
                if thermalSeriousSince == nil { thermalSeriousSince = now }
            } else {
                thermalSeriousSince = nil
            }

            if sample.cpuPercent > config.cpuTier2Percent {
                if cpuTier2Since == nil { cpuTier2Since = now }
                lastCpuTier2At = now
            } else if let last = lastCpuTier2At, now - last > config.cpuDipToleranceSeconds {
                cpuTier2Since = nil
                lastCpuTier2At = nil
            }

            if sample.memoryBytes > config.memoryTier2Bytes {
                if memoryTier2Since == nil { memoryTier2Since = now }
            } else {
                memoryTier2Since = nil
            }

            if let since = cpuTier2Since, now - since >= config.cpuTier2SustainSeconds {
                return enterTier2(.cpu)
            }
            if let since = memoryTier2Since, now - since >= config.memoryTier2SustainSeconds {
                return enterTier2(.memory)
            }
            if let since = thermalSeriousSince, now - since >= config.thermalSeriousStopSeconds {
                return enterTier2(.thermal)
            }

            // Hysteresis: recovery needs CPU at/below the release level, memory
            // under cap and no serious thermal, held for `recoverySeconds`.
            let calm = sample.cpuPercent <= config.cpuReleasePercent && !memoryOver && !thermalSerious
            if calm {
                if calmSince == nil { calmSince = now }
                if let since = calmSince, now - since >= config.recoverySeconds {
                    reset()
                    return .ok
                }
            } else {
                calmSince = nil
            }
            return .tier1Pause
        }
    }

    private func enterTier1(_ reason: ResourceTrigger, at now: TimeInterval) -> ResourceDecision {
        tier = .tier1
        trigger = reason
        calmSince = nil
        return .tier1Pause
    }

    private func enterTier2(_ reason: ResourceTrigger) -> ResourceDecision {
        tier = .tier2
        trigger = reason
        return .tier2Stop
    }
}
