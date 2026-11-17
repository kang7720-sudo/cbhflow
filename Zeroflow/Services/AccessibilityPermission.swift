import AppKit
import ApplicationServices

/// 辅助功能权限检测（Dock 单击最小化等依赖 AX 的能力）
enum AccessibilityPermission {
    private static let lock = NSLock()
    private static var cached: (granted: Bool, at: CFAbsoluteTime)?
    private static var didStartObserving = false

    /// 事件 tap 回调会按每次鼠标移动/按键调用这里；`AXIsProcessTrusted()` 是系统调用，
    /// 缓存 1s 足够（授权变化后事件 tap 本来也要靠 2s 重试才能生效），避免热路径反复询问。
    static var isGranted: Bool {
        lock.lock()
        if let cached, CFAbsoluteTimeGetCurrent() - cached.at < 1 {
            lock.unlock()
            return cached.granted
        }
        lock.unlock()

        let granted = AXIsProcessTrusted()
        lock.lock()
        cached = (granted, CFAbsoluteTimeGetCurrent())
        lock.unlock()
        return granted
    }

    /// 需要立即复核时调用（如从系统设置返回）
    static func refresh() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// 注册「回到前台即刷新」：用户去系统设置授权后回来，缓存立刻作废
    static func startObserving() {
        guard !didStartObserving else { return }
        didStartObserving = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            refresh()
        }
    }

    /// 弹出系统「辅助功能」授权窗口
    static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}
