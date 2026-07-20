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
/// - `tier2Stop`: hard stop — sustained overload or thermal pressure; the app should
///   route through its normal `stopListening` teardown.
enum ResourceDecision: Sendable, Equatable {
    case ok
    case tier1Pause
    case tier2Stop
}

/// Tunable thresholds. Defaults track the plan's tier values; kept in one struct so
/// they can be overridden in tests and adjusted later without touching the logic.
struct ResourceGovernorConfig: Sendable, Equatable {
    /// CPU percentage above which the Tier-1 sustain clock starts running.
    var cpuTier1Percent: Double
    /// How long CPU must stay above `cpuTier1Percent` before Tier-1 engages.
    var cpuSustainSeconds: TimeInterval
    /// Resident-memory cap; crossing it engages Tier-1 immediately (no sustain).
    var memoryTier1Bytes: UInt64
    /// How long load may stay high after Tier-1 before escalating to Tier-2.
    var tier2EscalationSeconds: TimeInterval
    /// Hysteresis release: Tier-1 only starts recovering once CPU is at or
    /// below this (below the engage threshold, so load oscillating around the
    /// engage point can't flap the tier on and off).
    var cpuReleasePercent: Double
    /// How long load must stay at/below `cpuReleasePercent` (and memory under
    /// cap) before Tier-1 actually releases back to normal.
    var recoverySeconds: TimeInterval
    /// Brief sub-threshold dips shorter than this do NOT reset the sustain
    /// run — spiky-but-consistently-high load (one 750 ms dip every few
    /// samples) previously never accumulated 20 s of "sustained" and the
    /// valve never engaged.
    var cpuDipToleranceSeconds: TimeInterval

    static let `default` = ResourceGovernorConfig(
        cpuTier1Percent: 70,
        cpuSustainSeconds: 20,
        memoryTier1Bytes: 1_500_000_000, // ~1.5 GB
        tier2EscalationSeconds: 15,
        cpuReleasePercent: 60,
        recoverySeconds: 5,
        cpuDipToleranceSeconds: 2
    )
}

/// Pure decision module for the performance safety valve. No I/O, no sampling, no
/// timers of its own — the caller supplies each `ResourceSample` together with a
/// monotonic timestamp (seconds), so behavior is fully deterministic and testable
/// with a controllable clock.
///
/// State machine:
/// - **normal → tier1** when CPU stays above the threshold for `cpuSustainSeconds`,
///   or when memory crosses `memoryTier1Bytes` (immediate, no sustain).
/// - **normal/tier1 → tier2** immediately on thermal `.serious`/`.critical`.
/// - **tier1 → tier2** when load stays high for `tier2EscalationSeconds` after the
///   Tier-1 entry.
/// - **tier1 → normal** as soon as load recovers below the thresholds.
/// - **tier2** is terminal until `reset()` (the app has torn down listening).
final class ResourceGovernor {
    enum Tier: Sendable, Equatable {
        case normal
        case tier1
        case tier2
    }

    private let config: ResourceGovernorConfig
    private(set) var tier: Tier = .normal

    /// When CPU first crossed `cpuTier1Percent` in the current over-threshold run;
    /// nil once CPU has been at/below threshold longer than the dip tolerance.
    private var cpuOverSince: TimeInterval?
    /// Most recent over-threshold sample time; drives the dip tolerance.
    private var lastCpuOverAt: TimeInterval?
    /// When Tier-1 was entered; drives the Tier-2 escalation clock.
    private var tier1Since: TimeInterval?
    /// When load first dropped to/below the release threshold while in Tier-1;
    /// drives the recovery sustain.
    private var calmSince: TimeInterval?

    init(config: ResourceGovernorConfig = .default) {
        self.config = config
    }

    /// Clears all state back to `normal`. Called when listening stops so a fresh
    /// session starts with a clean valve.
    func reset() {
        tier = .normal
        cpuOverSince = nil
        lastCpuOverAt = nil
        tier1Since = nil
        calmSince = nil
    }

    /// Feed one sample taken at monotonic time `now` (seconds). Returns the action
    /// the app should take. `now` must be non-decreasing across calls.
    func evaluate(_ sample: ResourceSample, at now: TimeInterval) -> ResourceDecision {
        // Thermal pressure is the hardest signal and short-circuits everything:
        // a hot machine won't recover by merely pausing aux work.
        if sample.thermalState == .serious || sample.thermalState == .critical {
            tier = .tier2
            return .tier2Stop
        }

        // Track the CPU sustain window. Dips shorter than the tolerance don't
        // reset the run (spiky-but-high load still counts as sustained); a
        // longer stretch below threshold resets it so a brief spike never
        // accumulates toward "sustained".
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

        switch tier {
        case .tier2:
            // Terminal until reset() — the app is tearing listening down.
            return .tier2Stop

        case .normal:
            if cpuSustained || memoryOver {
                tier = .tier1
                tier1Since = now
                calmSince = nil
                return .tier1Pause
            }
            return .ok

        case .tier1:
            // Hysteresis: recovery only starts once CPU is at/below the release
            // threshold (below the engage threshold) AND memory is under cap,
            // and only completes after `recoverySeconds` of continuous calm.
            // Releasing on a single sub-threshold sample made load oscillating
            // around the engage point flap Tier-1 on/off — each engage cancels
            // in-flight AI completions, so flapping was user-visible.
            let calm = sample.cpuPercent <= config.cpuReleasePercent && !memoryOver
            if calm {
                if calmSince == nil { calmSince = now }
                if let since = calmSince, now - since >= config.recoverySeconds {
                    reset()
                    return .ok
                }
                return .tier1Pause
            }
            calmSince = nil

            // Escalate only on instantaneously-high load (CPU over the engage
            // threshold or memory over cap). The middle band between release
            // and engage holds Tier-1 without escalating.
            let stillHigh = cpuOver || memoryOver
            if stillHigh, let since = tier1Since, now - since >= config.tier2EscalationSeconds {
                tier = .tier2
                return .tier2Stop
            }
            return .tier1Pause
        }
    }
}
