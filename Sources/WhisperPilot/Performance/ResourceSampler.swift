import Darwin
import Foundation

/// Produces one `ResourceSample` on demand. Injected into the coordinator so the
/// production reader (own-process CPU via `thread_info`, resident memory via
/// `task_info`, and `ProcessInfo.thermalState`) can be swapped for a synthetic
/// stub in tests. Stateless: each `sample()` is an instantaneous reading, so the
/// monotonic-clock bookkeeping the governor needs lives entirely in the caller.
protocol ResourceSampling: AnyObject, Sendable {
    func sample() -> ResourceSample
}

/// Real sampler. Reads this process only — never the whole machine — so the
/// governor reacts to load *we* are responsible for, not to an unrelated build
/// hammering the CPU in another app.
final class ResourceSampler: ResourceSampling {
    func sample() -> ResourceSample {
        ResourceSample(
            cpuPercent: Self.currentCPUPercent(),
            memoryBytes: Self.residentMemoryBytes(),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Sum of per-thread CPU usage for this task, as a percentage. One fully
    /// pinned core reads ≈ 100, so this can exceed 100 on a multi-core machine —
    /// matching the raw-load contract `ResourceSample.cpuPercent` documents.
    private static func currentCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return 0
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: UnsafeRawPointer(threadList))),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
                infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), rawPtr, &count)
                }
            }
            // Every entry in `threadList` carries a +1 send right that
            // `vm_deallocate` on the array does NOT release. Without this,
            // the port table grows by ~thread-count on every sample (~750 ms
            // cadence) until port-namespace exhaustion kills the process in
            // long sessions.
            mach_port_deallocate(mach_task_self_, threadList[index])
            guard kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
        return total
    }

    /// Memory footprint of this process, in bytes. Uses `phys_footprint`
    /// (TASK_VM_INFO) rather than `resident_size`: RSS counts clean mmapped
    /// pages — including the CoreML model weights Parakeet maps in — so a
    /// session could trip the governor's memory cap *because* the
    /// high-accuracy engine loaded, even though that memory is reclaimable
    /// and exerts no real pressure. `phys_footprint` is the same metric the
    /// kernel's own memory-pressure accounting (and Xcode's memory gauge) use.
    private static func residentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rawPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
