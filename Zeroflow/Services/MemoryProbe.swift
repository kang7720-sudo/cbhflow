import Foundation
import Darwin

/// 调试用内存探针：`ZEROFLOW_MEM_DEBUG=1` 每 30s 打一次 footprint；
/// `ZEROFLOW_MEM_CYCLE` 存在时也会启用 deinit 计数。Release 下默认完全静默。
enum MemoryProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let isLoggingEnabled = env["ZEROFLOW_MEM_DEBUG"] == "1"
    static let isEnabled = isLoggingEnabled || !(env["ZEROFLOW_MEM_CYCLE"] ?? "").isEmpty

    struct Snapshot {
        let footprint: UInt64
        let resident: UInt64
        let compressed: UInt64
        let mallocInUse: UInt64
        let blocks: UInt64

        var footprintMB: Double { Double(footprint) / 1024 / 1024 }
        var residentMB: Double { Double(resident) / 1024 / 1024 }
        var compressedMB: Double { Double(compressed) / 1024 / 1024 }
        var mallocMB: Double { Double(mallocInUse) / 1024 / 1024 }
    }

    private static var timer: Timer?
    private static let lock = NSLock()
    private static var deinitCounts: [String: Int] = [:]

    static func startIfNeeded() {
        guard isLoggingEnabled, timer == nil else { return }
        log("start")
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            log("tick")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func snapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        guard result == KERN_SUCCESS else {
            return Snapshot(footprint: 0, resident: 0, compressed: 0,
                            mallocInUse: UInt64(stats.size_in_use), blocks: UInt64(stats.blocks_in_use))
        }
        return Snapshot(footprint: UInt64(info.phys_footprint),
                        resident: UInt64(info.resident_size),
                        compressed: UInt64(info.compressed),
                        mallocInUse: UInt64(stats.size_in_use),
                        blocks: UInt64(stats.blocks_in_use))
    }

    static func log(_ tag: String) {
        let s = snapshot()
        ZSLog(String(format: "MEM %@ footprint=%.1fMB resident=%.1fMB compressed=%.1fMB malloc=%.1fMB blocks=%lld",
                     tag, s.footprintMB, s.residentMB, s.compressedMB, s.mallocMB, Int64(s.blocks)))
    }

    /// 对象销毁打点：同一类型只打前 3 次和每 20 次，避免 200 次循环刷屏。
    static func noteDeinit(_ name: String) {
        guard isEnabled else { return }
        lock.lock()
        let total = (deinitCounts[name] ?? 0) + 1
        deinitCounts[name] = total
        lock.unlock()
        if total <= 3 || total % 20 == 0 {
            ZSLog("MEM deinit \(name) total=\(total)")
        }
    }
}
