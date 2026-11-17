import AppKit

/// 调试用循环压测：`ZEROFLOW_MEM_CYCLE=notch:200`（可选 clipboard / switcher / editor）
/// 自动开/关同一功能 N 次，按周期打 footprint，用来区分「缓存涨到上限」和「每用一次都漏」。
/// `ZEROFLOW_MEM_CYCLE_EXIT=1` 在跑完后退出，方便脚本化采集。
enum MemoryCycleRunner {
    private enum Feature: String {
        case notch, clipboard, switcher, editor

        var delays: (openMs: Int, closeMs: Int) {
            switch self {
            case .notch: return (800, 900)
            case .clipboard: return (500, 400)
            case .switcher: return (1200, 400)
            case .editor: return (700, 500)
            }
        }
    }

    private static var feature: Feature?
    private static var total = 0
    private static var completed = 0
    private static var startFootprint: Double = 0
    private static var openMs = 0
    private static var closeMs = 0

    static func startIfNeeded() {
        guard let raw = ProcessInfo.processInfo.environment["ZEROFLOW_MEM_CYCLE"], !raw.isEmpty else {
            return
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: true)
        guard let feature = Feature(rawValue: String(parts[0])) else {
            ZSLog("MEM cycle: unknown feature '\(raw)' (expected notch|clipboard|switcher|editor)")
            return
        }
        let count = parts.count > 1 ? (Int(parts[1]) ?? 10) : 10
        let openMs = parts.count > 2 ? (Int(parts[2]) ?? feature.delays.openMs) : feature.delays.openMs
        let closeMs = parts.count > 3 ? (Int(parts[3]) ?? feature.delays.closeMs) : feature.delays.closeMs
        self.feature = feature
        self.total = max(0, count)
        self.completed = 0
        self.openMs = max(0, openMs)
        self.closeMs = max(0, closeMs)
        // 等启动后的服务装配/首帧稳定再开始
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            startFootprint = MemoryProbe.snapshot().footprintMB
            MemoryProbe.log("cycle-start \(feature.rawValue) count=\(total)")
            runNext()
        }
    }

    private static func runNext() {
        guard let feature else { return }
        guard completed < total else {
            finish(feature)
            return
        }
        open(feature)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(openMs)) {
            close(feature)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(closeMs)) {
                completed += 1
                if completed <= 5 || completed % 10 == 0 {
                    MemoryProbe.log("cycle \(feature.rawValue) \(completed)/\(total)")
                }
                runNext()
            }
        }
    }

    private static func finish(_ feature: Feature) {
        let end = MemoryProbe.snapshot()
        let delta = end.footprintMB - startFootprint
        let perCycle = total > 0 ? delta / Double(total) : 0
        MemoryProbe.log("cycle-end \(feature.rawValue) n=\(total) delta=\(String(format: "%.1f", delta))MB perCycle=\(String(format: "%.2f", perCycle))MB")
        if ProcessInfo.processInfo.environment["ZEROFLOW_MEM_CYCLE_EXIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func open(_ feature: Feature) {
        switch feature {
        case .notch:
            NotchHotspotController.shared.debugCyclePresent()
        case .clipboard:
            // 顺带展开预览：预览解码才是这条链的内存大头（DEV-054），只开关面板测不出来
            ClipboardPanelController.shared.showForDebug(expandAfter: 0.35)
        case .switcher:
            CommandTabSwitcher.shared.debugCycleBegin()
        case .editor:
            CaptureCoordinator.shared.openEditorForDebug(size: NSSize(width: 5120, height: 2880))
        }
    }

    private static func close(_ feature: Feature) {
        switch feature {
        case .notch:
            NotchHotspotController.shared.debugCycleHide()
        case .clipboard:
            ClipboardPanelController.shared.dismiss()
        case .switcher:
            CommandTabSwitcher.shared.debugCycleEnd()
        case .editor:
            CaptureCoordinator.shared.closeEditorForDebug()
        }
    }
}
