import AppKit
import ApplicationServices
import CoreGraphics

/// Dock 悬停窗口预览：鼠标悬停在 Dock 应用图标（或最小化窗口瓦片）上，
/// 弹出该窗口集合的缩略图预览面板，点击卡片切换窗口、悬停卡片出关闭按钮。
///
/// 实现要点（结构仿 `DockClickMinimizer` / `CommandTabSwitcher`，Dock AX 探测为本模块
/// 独立拷贝，不与 DockClickMinimizer 共享实现，避免互相牵连回归）：
/// - CGEventTap `.listenOnly` 监听 mouseMoved + mouseDown，**绝不吞事件**，
///   Dock 原生行为（启动/聚焦/右键菜单/按住 App Exposé）与 DockClickMinimizer 零影响。
/// - move 回调内只做内存几何判定（缓存的 Dock 项 frame contains），零 AX 调用；
///   目标变化防抖（悬停延时）到期后才在后台做一次「AX 权威命中测试 + WindowList 枚举」，
///   放大/自动隐藏/缓存过期都由这次权威命中兜底。
/// - Dock 项缓存：AX 遍历 Dock 应用元素的 kAXChildren 树收集 AXApplicationDockItem
///   （Dock 的 kAXWindows 恒为空，实测拿不到任何窗口）；app 项身份走 kAXURLAttribute
///   （.app URL → bundleID），无 URL 项记录标题作为「最小化窗口瓦片」候选
///   （展示时按标题反查最小化窗口；堆栈/废纸篓通常匹配不到）。
/// - **多显示器**：macOS 给每块屏各配一个 Dock，但 Dock 的 AX 树只暴露**一块屏**的图标
///   （跟着主屏走，不跟指针走；实测 kAXWindows=0、应用子元素只有一个 AXList）。
///   因此触发/闸门**不能**建立在「单条 Dock bbox」上，而是每块屏各取一条 Dock 边缘带
///   （`dockBandZonesTL`：Dock 贴哪条边就取那条边的整条带，厚度优先用
///   frame−visibleFrame 实测、自动隐藏时用常量兜底），指针落在任一块屏的带内即挂起；
///   真正「在不在图标上」只由 AX 权威命中判定。
/// - 窗口列表 = `WindowList.shared.enumerate()` 按 bundleID 过滤，与 ⌘⇥ 切换器**完全同源**
///   （含最小化与其他 Space 的窗口，不做特殊处理）；无窗口 app 不弹、无占位卡。
/// - 状态机：idle →(进入 Dock 边缘/命中图标)→ pending(延时) → visible；
///   visible 时鼠标移入面板保活（锚点冻结，图标缩放不跟随），移出「图标 / 面板 /
///   图标→面板走廊」后按「收起延迟」隐藏。弹出/收起两个延时都在设置页用滑杆控制
///   （`dockPreviewHoverDelayMs` / `dockPreviewHideDelayMs`），每次调度时现读，即时生效。
/// - 全局隐藏：任意 mouseDown（放行原生行为）/ Space 切换 / 锁屏睡眠 / 目标 app 退出 /
///   Dock 重启 / 任意按键 / 屏幕配置变化。
/// - 快路径命中失败或缓存无效时，pending 定时器照常触发并走权威命中，因此缓存仅是
///   「相邻图标重定向」的优化项，不是正确性依赖。
/// - 面板已显示时的「换目标」判定不能只靠缓存几何：放大（magnification）下缓存与冻结锚点
///   都是过期快照，指针踩到隔壁图标仍会命中原地，旧面板要等走出放大锚点才收。因此指针沿
///   Dock 轴移动超过阈值时节流（≤10Hz，异步、绝不阻塞事件 tap）问一次 AX 权威命中，
///   命中另一个目标就按换目标处理，「目标无窗口」时直接收起而不看保活区（DEV-067）。
/// - 自动隐藏 Dock：AX 给的是「隐藏位」坐标（整条落到屏幕边之外，比展开位低一条 Dock 高），
///   权威命中失败时在 Dock 落位前短期重试（指针停住后不再有 move 事件，只能自己轮询）。
///   **上屏前还要确认 Dock 真的推出来了**（`dockRevealState`）：主判据是 Dock 图标容器的
///   实时 AX frame 是否落回指针所在屏内，副判据是「指针刚贴过 Dock 那条边」（只放行不否决），
///   判不出来（多显示器副屏 / 侧边 Dock 退化坐标）时按旧行为放行。
final class DockHoverPreviewController {
    static let shared = DockHoverPreviewController()

    /// 开关变化通知：由 SettingsStore.dockPreviewEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockPreviewDidChange")

    /// 代码版本标记（只用于日志，排查「改了代码但跑的还是旧二进制」）
    private static let revision = "2026-11-16.dock-preview-r7"

    private static let dockBundleID = "com.apple.dock"
    private static let dockItemRole = "AXApplicationDockItem"
    /// Dock 项的通用角色：放大动画期间 `AXUIElementCopyElementAtPosition` 有时只给出
    /// 通用的 `AXDockItem`（实测同一坐标 170ms 后又能命中 `AXApplicationDockItem`），
    /// 严格按上面那个判定会把真实图标当成「不是 Dock 项」直接放弃
    private static let dockItemRoleLoose = "AXDockItem"
    /// 触发/闸门对 Dock 边缘带的外扩：触发稍早于进入，闸门拦截带外的误命中（如放大图标的「空气区」）
    private static let stripTriggerMargin: CGFloat = 30
    private static let stripGateMargin: CGFloat = 16
    /// 闸门对「命中项自身 frame」的外扩容差：命中项就在指针下，只需微宽容差
    private static let resolvedItemGateSlack: CGFloat = 4
    /// 权威命中失败后的短期重试（自动隐藏 Dock 的展开动画竞态）：间隔与总窗口（s）
    private static let resolveRetryInterval: TimeInterval = 0.12
    private static let resolveRetryWindow: TimeInterval = 1.2
    /// 每块屏 Dock 边缘带的**最小厚度**（pt）。Dock 自动隐藏时 `visibleFrame` 不减 Dock，
    /// 量不到真实厚度，用该常量兜住「展开后的图标区 + 放大外扩」。
    private static let bottomBandMinThickness: CGFloat = 96
    private static let sideBandMinThickness: CGFloat = 110
    /// 判定 Dock 贴哪条边时，`visibleFrame` 相对 `frame` 的最小 inset（低于该值视为该边没有 Dock）
    private static let dockInsetThreshold: CGFloat = 12
    /// 「Dock 是否真的在屏上」的**副**判据：指针贴住 Dock 那条边的判定宽度（pt）。
    /// 自动隐藏时系统只在指针压到屏幕边时才把 Dock 推出来，所以「刚贴过边」= Dock 展开过。
    /// 只在主判据（AX 条带实时位置）**无法判断**时用来放行，绝不用来否决（见 dockRevealState）。
    private static let revealSliver: CGFloat = 6
    /// 副判据的解除余量：指针离开 Dock 边缘带超过该距离才算「离开 Dock」（Dock 随之收起）
    private static let revealDisarmMargin: CGFloat = 24
    /// 主判据的贴合容差：Dock 图标容器沿 Dock 边法线离屏幕边不超过该值即视为「已推出」
    /// （隐藏位是整条外移一条 Dock 高，底部实测 ≈59pt；留 6pt 给展开动画的尾巴）
    private static let revealFlushTolerance: CGFloat = 6
    /// 实时换目标探测（DEV-067）：节流间隔 / 沿 Dock 轴的最小位移 / 结果过期的位移上限（pt）
    private static let liveProbeInterval: TimeInterval = 0.1
    private static let liveProbeAxisDelta: CGFloat = 8
    private static let liveProbeStaleDistance: CGFloat = 24
    /// 「换到隔壁图标」判定对**屏幕 Dock 边**的外扩（pt）：边缘带的跨度是从缓存条带推出来的，
    /// 缓存描述另一块屏时跨度未必对得上，这里按整条屏幕边兜底（副屏换目标靠它）
    private static let switchEdgeMargin: CGFloat = 110
    /// 保活判定对 图标/面板 的外扩（pt）：吞掉两者之间的缝隙，慢速移动不掉出保活区。
    /// 注意用法是 `insetBy(dx: -keepAliveInset, ...)`——负值才是外扩，正值会**内缩**，
    /// 在图标与面板之间留出一条 2×inset + 面板间距 的死带（DEV-060）。
    private static let keepAliveInset: CGFloat = 6
    /// 兜底命中测试时向上找 dock 项的父级深度上限
    private static let parentWalkDepth = 8
    /// move 事件处理节流间隔（s）：几何判定足够快，但没必要每个 HID 事件都跑
    private static let moveThrottle: CFTimeInterval = 0.016
    /// 右键菜单抑制：菜单开合探针的节流间隔 / 进入抑制后的确认探针延时（s）
    private static let menuProbeInterval: CFTimeInterval = 0.2
    private static let menuConfirmDelay: TimeInterval = 0.5

    private enum Phase { case idle, pending, visible }

    /// 展示目标：app 图标（该 app 的全部窗口）或最小化窗口瓦片（按标题反查）
    private enum HoverTarget {
        case app(NSRunningApplication, frameTL: CGRect)
        case tile(title: String, frameTL: CGRect)

        var frameTL: CGRect {
            switch self {
            case .app(_, let frameTL): return frameTL
            case .tile(_, let frameTL): return frameTL
            }
        }
    }

    /// Dock 项缓存条目（frame 为「主屏左上原点」全局坐标，与 CGEvent/AX 一致）
    private struct DockItem {
        let id: Int
        let frame: CGRect
        let app: NSRunningApplication?
        let title: String
    }

    // MARK: - 状态（lock 保护；tap 线程 / workQueue / 主线程共用）

    private let lock = NSLock()
    private var phase: Phase = .idle
    /// show 工作代数：scheduleShow 递增使旧 show 作废；hidePanel/failResolve 也递增
    private var showGen = 0
    /// 宽限隐藏代数：移出 图标∪面板 后挂 200ms 宽限隐藏（给「移向面板」留时间），
    /// 回到区域内即取消；与 showGen 分开避免互相误杀
    private var hideGen = 0
    /// 当前悬停候选（缓存项 id；缓存重建后可能错位，仅作优化信号）
    private var hoverItemID: Int?
    /// 已调度、尚未触发的 show 工作代数（防同一停留重复调度）
    private var pendingShowGen: Int?
    private var lastMousePoint = CGPoint.zero
    private var lastMoveProcessedAt = CFTimeInterval(0)
    /// Dock 项缓存
    private var dockItems: [DockItem] = []
    private var cacheInvalid = true
    private var pendingCacheRebuild: DispatchWorkItem?
    /// visible 时锚点与面板 frame（topLeft 坐标），用于「移出图标∪面板」判定
    private var currentItemTL: CGRect?
    private var panelFrameTL: CGRect?
    /// 点击卡片激活后的防重弹：指针仍停留在同一图标区域内时不再次弹出
    private var suppressKey: String?
    private var suppressRegionTL: CGRect?
    /// Dock 右键菜单打开期间的预览抑制：期间不调度/弹出预览，探针确认菜单关闭后自动解除
    private var contextMenuGuardActive = false
    private var lastMenuProbeAt = CFTimeInterval(0)
    /// 权威命中失败的短期重试截止时刻（nil = 未在重试）
    private var retryDeadline: CFTimeInterval?
    /// 自动隐藏 Dock 的副判据：指针刚贴过 Dock 那条边（系统展开 Dock 的唯一入口）。
    /// 主判据读不到（多显示器副屏 / 侧边 Dock 的退化坐标）时用它放行，见 dockRevealState。
    private var dockEdgeArmed = false
    /// 实时换目标探测：放大态下缓存与冻结锚点都是过期快照（DEV-067），指针可能已经踩到
    /// 隔壁图标而缓存仍说「在原地」。这里按「沿 Dock 轴位移 + 节流」异步问一次系统。
    private var lastLiveProbeAt = CFTimeInterval(0)
    private var lastLiveProbePoint = CGPoint.zero
    /// 已经探测到、正在等待 hoverDelay 换过去的目标身份（防连续 move 反复重置防抖）
    private var pendingSwitchKey: String?
    /// 当前展示目标的身份 key（与 suppressKey 同源）：用于判断「解析出的目标是另一个图标」
    private var currentTargetKey: String?

    // 主线程专用
    private var currentTarget: HoverTarget?
    private var currentWindows: [SwitcherWindow] = []
    private var panel: DockPreviewPanel?
    private let model = DockPreviewViewModel()
    private var keyMonitor: Any?
    /// 面板 orderFront 状态镜像（主线程）：软隐藏后置 false，present 后置 true
    private var panelShown = false
    /// 调试用：visible 阶段「是否在保活区」的上一次取值（只在事件 tap 线程读写），
    /// 用来只在状态**翻转**时打日志，避免每个 move 事件刷屏
    private var lastKeepAliveLogged = true

    // MARK: - 基础设施

    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: CFRunLoopTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "zeroflow.dock-hover-preview", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "zeroflow.dock-hover-cache")
    /// 调试日志开关：环境变量（命令行直启）或 UserDefaults（`open` 启动时也能开，便于真机排查）
    private static let debug: Bool = ProcessInfo.processInfo.environment["ZEROFLOW_DOCKPREVIEW_DEBUG"] == "1"
        || UserDefaults.standard.bool(forKey: "dockPreviewDebug")

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        observeHideTriggers()
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockPreviewEnabled {
            start()
        } else {
            stop()
        }
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        dockLayoutMayHaveChanged()
        installKeyMonitor()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-hover-preview"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        // rev 标记：排查「改了代码但跑的还是旧二进制」时，看这条就知道跑的是哪一版
        ZSLog("DockHoverPreview: started (rev=\(Self.revision))")
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        contextMenuGuardActive = false
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        let retry = retryTimer
        eventTap = nil
        retryTimer = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        removeKeyMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.teardown()
            self.model.items = []
            self.currentTarget = nil
            self.currentWindows = []
            self.panelShown = false
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        if let retry { CFRunLoopTimerInvalidate(retry) }
        thread = nil
        ZSLog("DockHoverPreview: stopped")
    }

    private func runTapLoop() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        lock.lock(); tapRunLoop = runLoop; lock.unlock()
        installTap(in: runLoop)
        // 兜底：tap 创建失败（如权限授权晚了）时周期重试，授权后无需重启即生效
        installRetryTimer(in: runLoop)
        CFRunLoopRun()
    }

    private func installTap(in runLoop: CFRunLoop) {
        // listen-only：只旁观，不吞事件（Dock 原生行为、DockClickMinimizer 均不受影响）
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockHoverPreview: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock()
        eventTap = tap
        let retry = retryTimer
        retryTimer = nil
        lock.unlock()
        if let retry { CFRunLoopTimerInvalidate(retry) }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockHoverPreview: tap installed OK")
    }

    private func installRetryTimer(in runLoop: CFRunLoop) {
        lock.lock()
        let hasTap = eventTap != nil
        let alreadyArmed = retryTimer != nil
        lock.unlock()
        guard !hasTap, !alreadyArmed else { return }
        var ctx = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 2,
            2,
            0,
            0,
            Self.retryTimerCallback,
            &ctx
        )
        guard let timer else { return }
        lock.lock()
        guard isRunning else {
            lock.unlock()
            CFRunLoopTimerInvalidate(timer)
            return
        }
        retryTimer = timer
        lock.unlock()
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    private func retryCreateTapIfNeeded() {
        lock.lock()
        let missing = eventTap == nil && isRunning
        let runLoop = tapRunLoop
        lock.unlock()
        if missing, let runLoop { installTap(in: runLoop) }
    }

    // MARK: - 事件回调（tap 线程）

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        return controller.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        controller.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.dockPreviewEnabled else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved:
            handleMouseMoved(event.location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleAnyMouseDown(at: event.location, type: type, flags: event.flags)
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 状态机（tap 线程决策，workQueue/主线程执行）

    private func isVisible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .visible
    }

    private func hoverDelay() -> TimeInterval {
        let ms = SettingsStore.shared.dockPreviewHoverDelayMs
        return TimeInterval(max(50, ms)) / 1000.0
    }

    /// 移出 图标∪面板 后的隐藏宽限（s）：设置页可调，给鼠标移向面板留时间。
    /// 0 视为立即收起（不额外延时）。
    private func hideDelay() -> TimeInterval {
        let ms = SettingsStore.shared.dockPreviewHideDelayMs
        return TimeInterval(max(0, ms)) / 1000.0
    }

    private func setHoverItem(_ id: Int) {
        lock.lock()
        hoverItemID = id
        lock.unlock()
    }

    /// 缓存命中测试（纯内存几何，零 AX 调用）。
    /// 返回项的 id / 缓存项 / **该屏上的真实 frame**（跨屏投影后的 frame）。
    ///
    /// 多显示器：Dock 的 AX 树只暴露**一块屏**的图标（DEV-058），缓存描述的也只是那块屏的布局。
    /// 其余屏按「各屏 Dock 内容与尺寸完全一致、各自居中（底部）或贴边（侧边）」把整条布局
    /// 平移到指针所在屏再命中——于是副屏的「换到隔壁图标」「右键抑制」和主屏走完全一样的
    /// 快路径，不必每次去问 AX（DEV-063）。
    private func cachedItem(at point: CGPoint) -> (id: Int, item: DockItem, frame: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        // 倒序遍历（后画的在绘制层级更上层）
        for item in dockItems.reversed() where item.frame.contains(point) {
            return (item.id, item, item.frame)
        }
        // 投影：把缓存布局按「屏中心 / 屏边」对齐到指针所在屏再命中。
        // 同一块屏也照做——自动隐藏的 Dock 在 AX 里常驻「隐藏位」（比展示位低一条 Dock 高），
        // 缓存可能一直停在那儿；对齐后偏移量正好把整条布局抬回展示位。
        guard let strip = bboxOfItems(dockItems), !isDegenerateDockFrame(strip),
              let from = nearestScreenTL(to: strip), let to = screenTL(containing: point) else { return nil }
        // 注意：这里不能用 dockEdge()——它的兜底分支会调 dockStripTL() 再取锁，NSLock 不可重入
        let offset: CGPoint
        switch Self.dockOrientationRaw() {
        case "left":
            offset = CGPoint(x: to.minX - strip.minX, y: to.midY - from.midY)
        case "right":
            offset = CGPoint(x: to.maxX - strip.maxX, y: to.midY - from.midY)
        default:
            offset = CGPoint(x: to.midX - from.midX, y: to.maxY - strip.maxY)
        }
        guard offset != .zero else { return nil }
        for item in dockItems.reversed() {
            let frame = item.frame.offsetBy(dx: offset.x, dy: offset.y)
            if frame.contains(point) { return (item.id, item, frame) }
        }
        return nil
    }

    /// Dock 朝向的全局偏好原值（left / right / bottom）。纯读，不取锁、不碰 NSScreen，
    /// 可以在 `cachedItem` 的锁内安全调用。
    private static func dockOrientationRaw() -> String? {
        CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
    }

    /// 实时换目标探测（DEV-067）。
    ///
    /// 面板已显示时，「指针是否还在当前图标上」原本只由缓存几何判定，而放大（magnification）
    /// 下缓存和冻结锚点都是**过期快照**：指针已经踩到隔壁图标，缓存仍说「在原地」，于是旧面板
    /// 要等指针走出放大后的锚点才收（表现为「必须多移一段才关」）。尺寸本身没有错，错在拿
    /// 历史快照当当前布局。
    ///
    /// 这里在**指针沿 Dock 轴位移超过阈值**时（节流 ≤10Hz）异步问一次系统「这个点是哪个图标」，
    /// 命中别的目标就按换目标处理；静止悬停时零开销。AX 调用**绝不能**在事件 tap 线程做——
    /// tap 有响应超时，慢了会被系统直接停掉，所以整段判定丢到 `workQueue`。
    private func probeLiveSwitchIfNeeded(_ point: CGPoint) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let lastPoint = lastLiveProbePoint
        let lastAt = lastLiveProbeAt
        let panel = panelFrameTL
        lock.unlock()
        // 指针在面板上（面板下沿可能压进边缘带）：那里没有 Dock 项，问了也是白问
        if let panel, panel.contains(point) { return }
        // 先过最便宜的节流/边带判定，别把 NSScreen 与偏好读取摊到每个 move 事件上
        guard now - lastAt >= Self.liveProbeInterval, isNearDockStrip(point) else { return }
        // 只认「沿 Dock 轴」的位移：从图标往面板上走是法线方向，不该触发换目标探测
        let edge = dockEdge()
        let delta = edge == .bottom ? abs(point.x - lastPoint.x) : abs(point.y - lastPoint.y)
        guard delta >= Self.liveProbeAxisDelta else { return }
        lock.lock()
        lastLiveProbeAt = now
        lastLiveProbePoint = point
        lock.unlock()

        workQueue.async { [weak self] in
            guard let self else { return }
            guard case .resolved(let target) = self.resolveTarget(at: point) else { return }
            let key = self.suppressKey(for: target)
            self.lock.lock()
            let current = self.currentTargetKey
            let alreadyPending = self.pendingSwitchKey == key
            let stillVisible = self.phase == .visible
            // 结果过期（这段时间指针又跑了很远）就丢弃，下一次 move 会重新探测
            let stale = abs(self.lastMousePoint.x - point.x) + abs(self.lastMousePoint.y - point.y)
                > Self.liveProbeStaleDistance
            if !stale, stillVisible {
                // 指针回到当前图标上 → 解除「等待换过去」，否则会一直挡住下次探测
                if key == current {
                    self.pendingSwitchKey = nil
                } else if !alreadyPending {
                    self.pendingSwitchKey = key
                }
            }
            self.lock.unlock()
            guard !alreadyPending, !stale, stillVisible, key != current else { return }
            if Self.debug { ZSLog("DockHoverPreview: switch by live hit pt=\(point) -> \(key)") }
            if let id = self.cachedItemID(matching: key) { self.setHoverItem(id) }
            self.scheduleShow(after: self.hoverDelay())
        }
    }

    private func handleMouseMoved(_ point: CGPoint) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveProcessedAt < Self.moveThrottle {
            lastMousePoint = point // 记录最新点，节流不影响权威命中的取点
            lock.unlock()
            return
        }
        lastMoveProcessedAt = now
        lastMousePoint = point
        let currentPhase = phase
        let hoverID = hoverItemID
        let panelFrame = panelFrameTL
        let anchorFrame = currentItemTL
        lock.unlock()

        // Dock 右键菜单打开期间：探针确认仍开着则本事件不参与悬停判定，
        // 菜单关闭（探针解除抑制）后照常恢复
        if isContextMenuGuarded() {
            probeContextMenuOpen()
            if isContextMenuGuarded() { return }
        }

        // 自动隐藏 Dock 的副判据：贴过边 = Dock 一定被推出来过（纯几何，零 AX）
        updateDockEdgeArmed(point)

        let hit = cachedItem(at: point)

        // 离开抑制区域即解除防重弹
        lock.lock()
        if suppressKey != nil, let region = suppressRegionTL, !region.contains(point) {
            suppressKey = nil
            suppressRegionTL = nil
        }
        lock.unlock()
        switch currentPhase {
        case .idle:
            if let entry = hit {
                if entry.id != hoverID {
                    setHoverItem(entry.id)
                    scheduleShow(after: hoverDelay())
                }
                // 同一图标内移动不重置计时
            } else if isNearDockStrip(point) {
                // 缓存未命中（无效/过期/放大中图标横移）：指针在 Dock 条带附近才挂延时，
                // 到期后由 AX 权威命中判定真正目标
                scheduleShowIfNone(after: hoverDelay())
            }

        case .pending:
            if let entry = hit, entry.id != hoverID {
                setHoverItem(entry.id)
                scheduleShow(after: hoverDelay()) // 换图标：重置防抖
            }
            // 其余情况：定时器继续倒数，到期权威判定

        case .visible:
            if let entry = hit, entry.id != hoverID {
                // 指针在「图标 → 面板」走廊里（去点面板的路上）不算换目标：放大 Dock 下
                // 缓存几何整体漂移，上行途中很容易误命中隔壁图标
                if isInTransitCorridor(point, anchor: anchorFrame, panel: panelFrame) {
                    bumpHideGen()
                    return
                }
                setHoverItem(entry.id)
                bumpHideGen() // 取消可能挂着的宽限隐藏，避免它杀掉在途 show
                // 换目标时**不**立刻收掉旧面板：路过/蹭到隔壁图标（鼠标去面板途中很常见）
                // 不该把面板打掉。新目标到期后由 present 原位换内容；解析失败（典型：隔壁
                // 图标没有窗口）时由 failResolve 按保活区决定去留——指针已离开 图标/面板/走廊
                // 就真收（见 isInKeepAliveRegion）。
                if Self.debug { ZSLog("DockHoverPreview: switch by cache pt=\(point) -> id=\(entry.id)") }
                scheduleShow(after: hoverDelay()) // 相邻图标：延时后原位换内容
                return
            }
            // 缓存没能识别出换目标时，再问一次系统（节流 + 只在沿 Dock 轴移动时）：
            // 放大态下缓存是过期快照，指针可能已经踩到隔壁图标而缓存仍命中原地（DEV-067）。
            probeLiveSwitchIfNeeded(point)
            // 面板显示中：仍在「图标 / 面板 / 图标→面板走廊」保活区内 → 保活
            // （不能用 图标∪面板 的包围矩形，否则隔壁图标也在里面，见 isInKeepAliveRegion）
            let keepAlive = isInKeepAliveRegion(point, anchor: anchorFrame, panel: panelFrame)
            if keepAlive != lastKeepAliveLogged {
                lastKeepAliveLogged = keepAlive
                if Self.debug {
                    ZSLog("DockHoverPreview: visible \(keepAlive ? "enter" : "leave") keep-alive pt=\(point) anchor=\(anchorFrame.map { "\($0)" } ?? "nil") panel=\(panelFrame.map { "\($0)" } ?? "nil")")
                }
            }
            if keepAlive {
                bumpHideGen() // 取消已调度的宽限隐藏
            } else if isNearDockStrip(point) || isNearDockEdge(point, margin: Self.switchEdgeMargin) {
                // 指针还在 Dock 边缘带里、但已离开当前图标：这是「换到隔壁图标」。
                // 缓存没覆盖这块屏时（副屏 Dock 的图标不在 AX 树里，见 DEV-058）hit 恒为 nil，
                // 只能按延时重新走一次 AX 权威命中——命中同一图标则内容不变，命中隔壁则原位换。
                lock.lock()
                let hasPendingShow = pendingShowGen != nil
                lock.unlock()
                if !hasPendingShow {
                    if Self.debug { ZSLog("DockHoverPreview: switch by AX (cache miss) pt=\(point)") }
                    scheduleShow(after: hoverDelay())
                }
            } else {
                // 移出保活区：不立即隐藏，挂「收起延迟」（设置页可调）——
                // 给「移向面板」留时间；在途 show（换目标重弹）时则交给 show 自行收尾
                lock.lock()
                let hasPendingShow = pendingShowGen != nil
                lock.unlock()
                if !hasPendingShow {
                    scheduleHideAfterGrace()
                }
            }
        }
    }

    private func handleAnyMouseDown(at point: CGPoint, type: CGEventType, flags: CGEventFlags) {
        lock.lock()
        let onPanel: Bool
        if let panelFrame = panelFrameTL, phase == .visible {
            onPanel = panelFrame.contains(point)
        } else {
            onPanel = false
        }
        let active = phase != .idle || pendingShowGen != nil
        lock.unlock()
        // 点击发生在自己面板上：放行（卡片点击/关闭钮需要收到这次 mouseDown），不隐藏
        if onPanel { return }
        // 右键（含 Ctrl+左键）落在 Dock 本体附近：大概率要弹 Dock 右键菜单，
        // 进入抑制直到菜单关闭——hidePanel 会清空 hoverItemID，否则指针在图标内
        // 稍一移动就会走 idle 分支重新 scheduleShow 弹出预览
        let menuOpener = type == .rightMouseDown
            || (type == .leftMouseDown && flags.contains(.maskControl))
        if menuOpener {
            enterContextMenuGuardIfDockZone(at: point)
        }
        // 其余任意 mouseDown：面板收起，事件放行（Dock 原生行为、DockClickMinimizer 不受影响）
        if active { hidePanel(reason: "mouseDown") }
    }

    // MARK: - 右键菜单抑制（Dock 菜单打开期间禁止弹出预览）

    private func isContextMenuGuarded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return contextMenuGuardActive
    }

    /// 右键打开 Dock 菜单只可能发生在 Dock 本体上：缓存命中图标，或落在某块屏的 Dock 边缘带内。
    /// 不用「屏幕任意边缘」兜底——屏幕中部右键不应进入抑制。
    private func isDockMenuLaunchZone(_ point: CGPoint) -> Bool {
        if cachedItem(at: point) != nil { return true }
        return isInDockZone(point, margin: Self.stripTriggerMargin)
    }

    private func enterContextMenuGuardIfDockZone(at point: CGPoint) {
        guard isDockMenuLaunchZone(point) else { return }
        lock.lock()
        let newlyArmed = !contextMenuGuardActive
        contextMenuGuardActive = true
        lock.unlock()
        if newlyArmed { ZSLog("DockHoverPreview: context menu guard on") }
        // 确认探针：菜单没真正弹出时（右键分隔符/空白处）尽快解除
        workQueue.asyncAfter(deadline: .now() + Self.menuConfirmDelay) { [weak self] in
            self?.probeContextMenuOpen(force: true)
        }
    }

    /// 节流探针：Dock AX 树里还挂着菜单 → 保持抑制；已关闭 → 解除。
    /// AX 扫描丢到 workQueue，不占用 tap 回调线程（listen-only 回调必须快）。
    private func probeContextMenuOpen(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard contextMenuGuardActive else { lock.unlock(); return }
        guard force || now - lastMenuProbeAt >= Self.menuProbeInterval else { lock.unlock(); return }
        lastMenuProbeAt = now
        lock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            let open = self.isDockContextMenuOpen()
            self.lock.lock()
            if self.contextMenuGuardActive && !open {
                self.contextMenuGuardActive = false
                ZSLog("DockHoverPreview: context menu guard off")
            }
            self.lock.unlock()
        }
    }

    /// Dock 应用元素的 AX 树里是否存在打开的菜单（右键菜单/子菜单）。
    /// resolveTarget 实测右键菜单元素可沿 Dock 层级命中（isMenuElement），浅层扫描即可。
    /// AX 调用失败一律视为未打开（自愈，避免抑制永久卡死）。
    private func isDockContextMenuOpen() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return false }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard var frontier = copyAXElements(dockElement, kAXChildrenAttribute), !frontier.isEmpty else { return false }
        for _ in 0..<3 {
            var next: [AXUIElement] = []
            for element in frontier {
                if isMenuElement(element) { return true }
                if let children = copyAXElements(element, kAXChildrenAttribute) {
                    next.append(contentsOf: children)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return false
    }

    // MARK: - 调度

    /// 保活：取消待触发的宽限隐藏（不动在途 show）
    private func bumpHideGen() {
        lock.lock()
        hideGen += 1
        lock.unlock()
    }

    /// 保活区：图标自身 ∪ 面板自身（各外扩 keepAliveInset），再加上「图标 → 面板」走廊。
    ///
    /// **不能用 `anchor.union(panel)` 的包围矩形**：底部 Dock 下它是一个横跨「图标最左 →
    /// 面板最右」的大矩形，横向远宽于图标本身，会把整条 Dock 的邻域一起吞掉——指针明明
    /// 停在隔壁图标上也被判成「还在原地」，于是换到**无窗口图标**时 `failResolve` 走
    /// 「keep panel」分支，旧面板永远不收（DEV-065）。
    /// 图标与面板之间即使有缝（放大图标缩回、锚点冻结在旧坐标）也由走廊覆盖，不需要并集。
    private func isInKeepAliveRegion(_ point: CGPoint, anchor: CGRect?, panel: CGRect?) -> Bool {
        let inflate = Self.keepAliveInset
        if let anchor, anchor.insetBy(dx: -inflate, dy: -inflate).contains(point) { return true }
        if let panel, panel.insetBy(dx: -inflate, dy: -inflate).contains(point) { return true }
        return isInTransitCorridor(point, anchor: anchor, panel: panel)
    }

    /// 「图标 → 面板」走廊：沿面板朝向轴从图标边缘延伸到面板边缘，横截面取图标自身跨度
    /// （再外扩 keepAliveInset）。指针走在这条走廊里就是在去点面板的路上，
    /// 不该被判定成「移到了隔壁图标」。两个矩形重叠/无明确朝向时返回 false（不做走廊判定）。
    private func isInTransitCorridor(_ point: CGPoint, anchor: CGRect?, panel: CGRect?) -> Bool {
        guard let anchor, let panel else { return false }
        let corridor: CGRect
        if panel.maxY <= anchor.minY {          // 面板在图标上方（底部 Dock）
            corridor = CGRect(x: anchor.minX, y: panel.maxY,
                              width: anchor.width, height: anchor.minY - panel.maxY)
        } else if panel.minY >= anchor.maxY {   // 面板在图标下方
            corridor = CGRect(x: anchor.minX, y: anchor.maxY,
                              width: anchor.width, height: panel.minY - anchor.maxY)
        } else if panel.maxX <= anchor.minX {   // 面板在图标左侧
            corridor = CGRect(x: panel.maxX, y: anchor.minY,
                              width: anchor.minX - panel.maxX, height: anchor.height)
        } else if panel.minX >= anchor.maxX {   // 面板在图标右侧
            corridor = CGRect(x: anchor.maxX, y: anchor.minY,
                              width: panel.minX - anchor.maxX, height: anchor.height)
        } else {
            return false
        }
        let inflate = Self.keepAliveInset
        return corridor.insetBy(dx: -inflate, dy: -inflate).contains(point)
    }

    /// 宽限隐藏：移出「图标 / 面板 / 图标→面板走廊」(外扩) 后按「收起延迟」仍在 visible 且无在途 show 才真正隐藏。
    /// 期间回到保活区（bumpHideGen）或调度了新 show（pendingShowGen 置位/作废本 hide）都会取消。
    /// 延迟每次调用时现读设置，改滑杆即时生效（无需重启）。
    private func scheduleHideAfterGrace() {
        lock.lock()
        hideGen += 1
        let h = hideGen
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + hideDelay()) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = h == self.hideGen && self.phase == .visible && self.pendingShowGen == nil
            self.lock.unlock()
            guard live else { return }
            self.hidePanel(reason: "left icon+panel region")
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        lock.lock()
        showGen += 1
        let g = showGen
        pendingShowGen = g
        retryDeadline = nil
        if phase == .idle { phase = .pending }
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pendingShowGen == g { self.pendingShowGen = nil }
            let live = g == self.showGen && (self.phase == .pending || self.phase == .visible)
            self.lock.unlock()
            guard live else { return }
            self.resolveAndShow(showGen: g)
        }
    }

    /// 仅当没有任何挂起的 show 时调度（防止边缘区连续移动重复触发）
    private func scheduleShowIfNone(after delay: TimeInterval) {
        lock.lock()
        let none = pendingShowGen == nil
        lock.unlock()
        guard none else { return }
        scheduleShow(after: delay)
    }

    private func hidePanel(reason: String) {
        lock.lock()
        phase = .idle
        hoverItemID = nil
        pendingShowGen = nil
        currentItemTL = nil
        panelFrameTL = nil
        suppressKey = nil
        suppressRegionTL = nil
        retryDeadline = nil
        currentTargetKey = nil
        pendingSwitchKey = nil
        showGen += 1
        lock.unlock()
        ZSLog("DockHoverPreview: hide (\(reason))")
        let dismiss = { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.teardown()
            self.panelShown = false
            self.model.items = []
            self.currentTarget = nil
            self.currentWindows = []
        }
        if Thread.isMainThread {
            dismiss()
        } else {
            DispatchQueue.main.async(execute: dismiss)
        }
    }

    // MARK: - 解析与展示（workQueue → 主线程）

    /// 延时到期：AX 权威命中 → 过滤窗口 → 主线程展示。
    /// 失败（不在 Dock 项上/命中右键菜单/目标无窗口）时回到 idle；面板已开则收起。
    private func resolveAndShow(showGen g: Int) {
        let point: CGPoint = {
            lock.lock(); defer { lock.unlock() }
            return lastMousePoint
        }()
        // 兜底：抑制期间到达的在途 show 一律不放行
        if isContextMenuGuarded() {
            failResolve(showGen: g, reason: "dock context menu open", retryable: false)
            return
        }
        let target: HoverTarget
        /// 目标是否来自**实时** AX 命中（而不是缓存/投影兜底）。只有实时命中才能断言
        /// 「指针确实在另一个图标上」，据此把旧面板直接收掉（DEV-067）。
        var liveResolved = false
        switch resolveTarget(at: point) {
        case .resolved(let resolved):
            target = resolved
            liveResolved = true
        case .failed, .notDockElement:
            // 缓存兜底（含跨屏投影）：AX 偶发失败，或这块屏的 Dock 根本不在 AX 树里
            // （多显示器，DEV-058）时，指针确实落在某个图标 frame 内就按它认。
            // 右键菜单单独走 .menuElement，不在这里兜底——否则菜单悬在图标上会弹出预览。
            guard let entry = cachedItem(at: point), let cached = targetFromCachedItem(entry) else {
                failResolve(showGen: g, reason: "no dock item at point")
                return
            }
            target = cached
        case .menuElement:
            failResolve(showGen: g, reason: "point is not a dock item")
            return
        }
        // 位置闸门：优先用「AX 权威命中到的图标自身 frame」（实时、不受 Dock 隐藏位影响），
        // 边缘带仅作兜底，防止放大图标的「空气区」/远处误命中。带是**每块屏各一条**，
        // 所以副屏 Dock 命中的图标不会被主屏条带拦掉。
        let anchorTL = sanitizedAnchor(target.frameTL, at: point)
        // 自动隐藏 Dock：先确认它**真的在屏上**（见 dockRevealState）。未展开时缓存投影会
        // 造出一个「展示位」frame，AX 权威命中又必然失败，于是指针只要压在屏幕底部就会
        // 弹面板；展开动画中途 AX 坐标还没到位，锚点偏低会让面板跟着偏下。
        let reveal = dockRevealState(at: point)
        if Self.debug {
            let bands = dockBandZonesTL().map { "\($0)" }.joined(separator: " | ")
            ZSLog("DockHoverPreview: resolve pt=\(point) target=\(targetLabel(target)) item=\(target.frameTL) anchor=\(anchorTL) edge=\(dockEdge()) settled=\(isDockSettled(at: point)) reveal=\(reveal) bands=[\(bands)]")
        }
        if reveal == .hidden {
            if Self.debug { ZSLog("DockHoverPreview: dock not revealed pt=\(point) liveStrip=\(liveDockStripTL().map { "\($0)" } ?? "nil")") }
            failResolve(showGen: g, reason: "dock not revealed")
            return
        }
        // 锚点体检：命中项/投影 frame 的中心必须落在指针所在屏内。隐藏位整条在屏幕外、
        // 展开动画中途 frame 偏低，两种情况都不该拿去定位面板（否则面板贴着一个屏外的
        // 「图标」，表现为面板偏下甚至半截出屏）。
        if let pointerScreen = screenTL(containing: point) {
            let anchorCenter = CGPoint(x: anchorTL.midX, y: anchorTL.midY)
            if !pointerScreen.insetBy(dx: -2, dy: -2).contains(anchorCenter) {
                if Self.debug { ZSLog("DockHoverPreview: anchor off screen pt=\(point) anchor=\(anchorTL) screen=\(pointerScreen)") }
                failResolve(showGen: g, reason: "anchor off screen")
                return
            }
        }
        let onResolvedItem = anchorTL.insetBy(dx: -Self.resolvedItemGateSlack, dy: -Self.resolvedItemGateSlack).contains(point)
        if !onResolvedItem, !isInDockZone(point, margin: Self.stripGateMargin) {
            if Self.debug { ZSLog("DockHoverPreview: gate reject pt=\(point)") }
            failResolve(showGen: g, reason: "pointer outside dock strip")
            return
        }
        // 点击卡片激活后的防重弹：同一目标且指针仍在原图标区域内 → 不弹
        lock.lock()
        var suppressed = false
        if let region = suppressRegionTL, let key = suppressKey, region.contains(point) {
            suppressed = key == self.suppressKey(for: target)
        }
        lock.unlock()
        if suppressed {
            failResolve(showGen: g, reason: "suppressed after activate", retryable: false)
            return
        }
        let windows = windows(for: target)
        guard !windows.isEmpty else {
            // 实时命中已确认指针在另一个图标上（而不是投影兜底猜的）→ 旧面板必须立刻收，
            // 不能交给保活区几何判断：放大态下锚点是过期快照，会误判「还在原地」（DEV-067）。
            var different = false
            if liveResolved {
                lock.lock()
                let current = currentTargetKey
                lock.unlock()
                different = current != nil && current != suppressKey(for: target)
            }
            failResolve(showGen: g, reason: "target has no windows",
                        retryable: false, differentTarget: different)
            return
        }
        syncDockCache(with: target)
        DispatchQueue.main.async { [weak self] in
            self?.present(windows: windows, target: target, showGen: g, pointer: point)
        }
    }

    /// 权威命中失败/无窗口：指针仍在 Dock 区域内且 Dock 尚未落位时先短期重试
    /// （自动隐藏 Dock 的展开动画中图标坐标/命中结果还在变，而指针停住不再产生
    /// mouseMoved），重试用尽才回到 idle；面板已开着则在回 idle 时收起。
    /// - Parameter differentTarget: 实时命中已确认指针在**另一个** Dock 项上。
    ///   此时保活区不可信（放大态下锚点是过期快照，可能覆盖到隔壁图标，DEV-067），
    ///   直接收起旧面板，不再按几何保活。
    private func failResolve(showGen g: Int, reason: String, retryable: Bool = true, differentTarget: Bool = false) {
        if retryable, scheduleResolveRetry(showGen: g, reason: reason) { return }
        lock.lock()
        let wasVisible = phase == .visible
        let point = lastMousePoint
        let anchor = currentItemTL
        let panel = panelFrameTL
        lock.unlock()
        // 面板已经开着、指针仍在保活区里（正往面板上走，或蹭到隔壁图标后继续上行）→
        // 这只是一次「换目标」没解析出东西，不该把当前面板收掉：作废这次 show，
        // 面板与状态原样保留，去留交给保活判定/收起延迟。
        // 指针停在**隔壁图标**上（保活区外，或已被实时命中确认换了目标）则走下面的收起分支，
        // 旧面板不能赖着不走。
        if wasVisible, !differentTarget, isInKeepAliveRegion(point, anchor: anchor, panel: panel) {
            lock.lock()
            if g == self.showGen {
                pendingShowGen = nil
                showGen += 1
                hideGen += 1 // 顺手作废可能挂着的宽限隐藏，避免它杀掉保留下来的面板
            }
            lock.unlock()
            if Self.debug { ZSLog("DockHoverPreview: keep panel, resolve miss (\(reason))") }
            return
        }
        lock.lock()
        if g == self.showGen {
            phase = .idle
            hoverItemID = nil
            currentItemTL = nil
            panelFrameTL = nil
            retryDeadline = nil
            currentTargetKey = nil
            pendingSwitchKey = nil
            showGen += 1
            pendingShowGen = nil
        }
        lock.unlock()
        if wasVisible {
            hidePanel(reason: reason)
        } else {
            ZSLog("DockHoverPreview: resolve failed (\(reason))")
        }
    }

    /// 是否值得短期重试：指针仍在 Dock 区域附近时，一次命中失败不足以判定「指针真的不在图标上」。
    /// 两类时序竞态都会给出「不是 Dock 图标」的假失败：
    /// ① 自动隐藏 Dock 的展开动画期间 AX 坐标还是隐藏位；
    /// ② **放大动画期间**（magnification）图标正在平移，同一坐标前后 170ms 命中结果都不一样
    ///    （实测会命中通用的 AXDockItem 角色而不是 app 项）。
    /// 面板已经开着时重试期间旧面板保持不动，不会闪；预算用完才真收。
    private func scheduleResolveRetry(showGen g: Int, reason: String) -> Bool {
        lock.lock()
        let point = lastMousePoint
        lock.unlock()
        guard isNearDockStrip(point) else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard g == self.showGen, pendingShowGen == nil else { lock.unlock(); return false }
        // 首次重试才开始计时窗口，后续沿用同一 deadline
        let deadline = retryDeadline ?? (now + Self.resolveRetryWindow)
        retryDeadline = deadline
        let hasBudget = now < deadline
        lock.unlock()
        guard hasBudget else { return false }

        if Self.debug { ZSLog("DockHoverPreview: resolve retry (\(reason))") }
        workQueue.asyncAfter(deadline: .now() + Self.resolveRetryInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = g == self.showGen && self.pendingShowGen == nil
            self.lock.unlock()
            guard live else { return }
            self.resolveAndShow(showGen: g)
        }
        return true
    }

    /// Dock 是否已完全落位：AX 给的图标条带整体落在某块屏内即为已落位；
    /// 自动隐藏的展开动画期间 AX 坐标还是「隐藏位」（整条在屏幕外）→ false。
    /// 多显示器：缓存描述的是另一块屏的 Dock 时无法判断该屏是否落位，也按未落位处理。
    /// 注意：**不再**用它当重试门槛——放大动画期间条带是「已落位」的，但图标仍在平移，
    /// 命中照样会假失败（见 scheduleResolveRetry）。保留给调试/诊断用。
    private func isDockSettled(at point: CGPoint) -> Bool {
        guard let strip = dockStripTL(), !isDegenerateDockFrame(strip),
              let stripScreen = nearestScreenTL(to: strip) else { return false }
        if let pointerScreen = screenTL(containing: point), pointerScreen != stripScreen { return false }
        let inter = stripScreen.intersection(strip)
        guard !inter.isNull, strip.width > 0, strip.height > 0 else { return false }
        return inter.width * inter.height >= strip.width * strip.height * 0.95
    }

    // MARK: - Dock 展开状态（自动隐藏）

    /// Dock 当前是否真的在屏上（只有自动隐藏时才可能「不在」）。
    /// `unknown` = 判不出来（多显示器副屏 / 侧边 Dock 的 AX 退化坐标 / AX 读不到），
    /// 调用方按旧行为放行——宁可保留偶发误弹，也不让这些配置直接失效。
    private enum DockRevealState { case revealed, hidden, unknown }

    /// `com.apple.dock` 的 autohide 开关（系统级设置）。纯读，不取锁、不碰 NSScreen。
    private static func isDockAutoHidden() -> Bool {
        guard let raw = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) else {
            return false
        }
        if let number = raw as? NSNumber { return number.boolValue }
        return raw as? Bool ?? false
    }

    /// Dock 图标容器的**实时** frame（不是缓存：缓存可能长期停在隐藏位）。
    /// Dock 的 AX 树只有一个图标容器（实测应用子元素只有一个 AXList），隐藏时整条落到
    /// 屏幕边之外、展开时回到屏内，正好可以当「是否展开」的判据。
    /// 侧边 Dock 自动隐藏时给的是退化坐标（16×0）→ 返回 nil（判不出来）。
    private func liveDockStripTL() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let roots = copyAXElements(dockElement, kAXChildrenAttribute), !roots.isEmpty else { return nil }
        var bbox = CGRect.null
        for root in roots {
            guard let point = axPoint(root, kAXPositionAttribute),
                  let size = axSize(root, kAXSizeAttribute) else { continue }
            bbox = bbox.union(CGRect(origin: point, size: size))
        }
        return bbox.isNull ? nil : bbox
    }

    /// 自动隐藏模式下 Dock 是否已经推出来（含「展开动画已基本落位」）。
    ///
    /// 主判据：`liveDockStripTL()` 是否**贴合指针所在屏的 Dock 那条边**。缓存兜底（跨屏投影）会
    /// 凭空造出一个「展示位」frame，AX 权威命中又必然失败，于是「指针压在屏幕底部、Dock 还收着」
    /// 也会弹面板；展开动画中途 AX 坐标还没到位，面板会被贴着一个偏低的「图标」定位。
    /// 副判据（只在主判据判不出来时放行）：指针刚贴过 Dock 那条边——系统只在贴边时推出 Dock，
    /// 所以贴过边就说明它展开过；它**只放行不否决**，避免在无法实测的配置上造成回归。
    private func dockRevealState(at point: CGPoint) -> DockRevealState {
        guard Self.isDockAutoHidden() else { return .revealed }
        if let strip = liveDockStripTL(), !isDegenerateDockFrame(strip),
           let stripScreen = nearestScreenTL(to: strip),
           let pointerScreen = screenTL(containing: point) {
            if stripScreen == pointerScreen {
                // 只比「沿 Dock 边法线的贴合程度」，**不比面积**：放大动画期间条带会横向撑开
                // 约 30%，按面积比会被误判成「没展开」（面板就永远不弹了）。隐藏位是整条
                // 沿法线外移一条 Dock 高（底部实测 ≈59pt），贴合判定对两个方向都成立。
                let gap: CGFloat
                switch dockEdge() {
                case .bottom: gap = strip.maxY - pointerScreen.maxY
                case .left: gap = pointerScreen.minX - strip.minX
                case .right: gap = strip.maxX - pointerScreen.maxX
                }
                return gap <= Self.revealFlushTolerance ? .revealed : .hidden
            }
            // 条带属于另一块屏（Dock 的 AX 树只暴露一块屏）→ 主判据对这块屏无效
        }
        lock.lock()
        let armed = dockEdgeArmed
        lock.unlock()
        return armed ? .revealed : .unknown
    }

    /// 维护副判据：贴到 Dock 那条边（`revealSliver` 内）→ 记为「展开过」；
    /// 离开 Dock 边缘带（`revealDisarmMargin` 之外，Dock 随之收起）→ 解除。
    private func updateDockEdgeArmed(_ point: CGPoint) {
        guard Self.isDockAutoHidden() else {
            lock.lock()
            dockEdgeArmed = false
            lock.unlock()
            return
        }
        let touching = isNearDockEdge(point, margin: Self.revealSliver)
        let inside = touching || isInDockZone(point, margin: Self.revealDisarmMargin)
        guard touching || !inside else { return } // 带内但不贴边：保持原状态
        lock.lock()
        if dockEdgeArmed != touching { dockEdgeArmed = touching }
        lock.unlock()
    }

    /// 指针所在屏（左上原点全局坐标）
    private func screenTL(containing point: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            let frame = topLeftFrame(of: screen)
            if frame.contains(point) { return frame }
        }
        return nil
    }

    /// 权威命中的图标坐标与缓存不一致时（自动隐藏 Dock 展开前后 AX 坐标整体位移几十点），
    /// 触发防抖重建；否则快路径命中与「可见时换图标」判定会一直用隐藏位坐标。
    /// 多显示器：缓存描述的是**另一块屏**的 Dock 时坐标天然不同（AX 只暴露一块屏），
    /// 不做「过期」判定，否则每次悬停副屏都会白白重建一次缓存。
    private func syncDockCache(with target: HoverTarget) {
        let frame = target.frameTL
        let key = suppressKey(for: target)
        guard !isDegenerateDockFrame(frame) else { return }
        let stripScreen = dockStripTL().flatMap { isDegenerateDockFrame($0) ? nil : nearestScreenTL(to: $0) }
        guard stripScreen == nearestScreenTL(to: frame) else { return }
        lock.lock()
        var stale = false
        if !cacheInvalid {
            for item in dockItems where dockItemKey(item) == key {
                if abs(item.frame.minX - frame.minX) > 1 || abs(item.frame.minY - frame.minY) > 1
                    || abs(item.frame.width - frame.width) > 1 || abs(item.frame.height - frame.height) > 1 {
                    stale = true
                }
            }
        }
        lock.unlock()
        guard stale else { return }
        if Self.debug { ZSLog("DockHoverPreview: cache geometry stale, rebuild") }
        dockLayoutMayHaveChanged()
    }

    private func dockItemKey(_ item: DockItem) -> String {
        if let app = item.app {
            return "app:\(app.bundleIdentifier ?? "pid:\(app.processIdentifier)")"
        }
        return "tile:\(item.title)"
    }

    /// 缓存项 → 悬停目标（AX 不可用时的兜底）。frame 用**投影后**的 frame，
    /// 保证副屏上面板贴的是这块屏的图标，而不是缓存那块屏的坐标。
    private func targetFromCachedItem(_ entry: (id: Int, item: DockItem, frame: CGRect)) -> HoverTarget? {
        if let app = entry.item.app { return .app(app, frameTL: entry.frame) }
        if !entry.item.title.isEmpty { return .tile(title: entry.item.title, frameTL: entry.frame) }
        return nil
    }

    /// 目标的可读标识（调试日志用）
    private func targetLabel(_ target: HoverTarget) -> String {
        switch target {
        case .app(let app, _): return app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        case .tile(let title, _): return "tile:\(title)"
        }
    }

    /// 按身份（`suppressKey` 同款 key）反查缓存项的 id：指针不在缓存几何内时用它兜住 hoverItemID
    private func cachedItemID(matching key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        return dockItems.first { dockItemKey($0) == key }?.id
    }

    /// 目标 → 窗口列表（与 ⌘⇥ 切换器同源；无窗口 app 返回空 → 不弹）
    private func windows(for target: HoverTarget) -> [SwitcherWindow] {
        let all = WindowList.shared.enumerate()
        switch target {
        case .app(let app, _):
            let bundleID = app.bundleIdentifier
            let pid = app.processIdentifier
            return all.filter { window in
                guard !window.isWindowlessApp else { return false }
                if let bundleID { return window.app.bundleIdentifier == bundleID }
                return window.pid == pid
            }
        case .tile(let title, _):
            return all.filter { !$0.isWindowlessApp && $0.isMinimized && $0.title == title }
        }
    }

    /// 组装卡片模型：先用 WindowThumbnailer 的缓存旧图占位（抓过就有），
    /// 新图抓到后在 applyThumbnails 替换，避免空面板/闪烁。
    private func makeItems(_ windows: [SwitcherWindow]) -> [SwitcherWindow] {
        windows.map { window in
            var item = window
            item.thumbnail = WindowThumbnailer.shared.cachedThumbnail(for: window.id)
            return item
        }
    }

    /// 主线程：更新模型并弹出/刷新面板（复用同一面板实例，换图标仅换内容不闪烁）
    private func present(windows: [SwitcherWindow], target: HoverTarget, showGen generation: Int, pointer: CGPoint) {
        // 先在锁外取锚点图标缓存 id（cachedItem 内部会加锁，NSLock 不可重入，
        // 持锁调用会主线程死锁——面板永远弹不出来）。
        // 缓存失效/几何漂移时按目标身份兜底反查：hoverItemID 若留空，指针只要还压在同
        // 一个图标上就会被当成「换了目标」，每个 move 事件都重置一次防抖。
        let anchorItemID = cachedItem(at: pointer)?.id
            ?? cachedItemID(matching: suppressKey(for: target))
        // 锚点净化要在取锁之前算：sanitizedAnchor → dockBandZonesTL → dockStripTL 会再加锁，
        // NSLock 不可重入，持锁调用会把主线程锁死
        let anchorTL = sanitizedAnchor(target.frameTL, at: pointer)
        lock.lock()
        // 菜单抑制兜底：即使 generation/phase 均在途，菜单开着也不上屏
        guard generation == self.showGen, phase == .pending || phase == .visible, !contextMenuGuardActive else {
            lock.unlock()
            return
        }
        phase = .visible
        currentItemTL = anchorTL
        retryDeadline = nil
        // 同图标内移动走保活，不再误判为换目标；缓存无效时为 nil，靠 anchorFrame 保活
        hoverItemID = anchorItemID
        // 换目标已经落地：清掉「等待换过去」的标记，记下当前目标身份供实时命中比对（DEV-067）
        currentTargetKey = suppressKey(for: target)
        pendingSwitchKey = nil
        // 实时探测的位移基准从「面板弹出这一刻」开始算
        lastLiveProbeAt = 0
        lastLiveProbePoint = pointer
        lock.unlock()

        currentTarget = target
        currentWindows = windows
        model.items = makeItems(windows)

        let panel = ensurePanel()
        let placement = self.placement()
        panel.present(anchorTL: anchorTL,
                      placement: placement,
                      model: model,
                      onSelect: { [weak self] windowID in self?.activate(windowID: windowID) },
                      onClose: { [weak self] windowID in self?.close(windowID: windowID) })
        panelShown = true
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.frame)
        // 换目标/重弹刚上屏：作废此刻之前挂着的宽限隐藏——它是按旧锚点（隔壁图标）算出来的，
        // 指针停在新图标上不动时不会再有 move 事件来 bump，留着它会把新面板 500ms 后收掉
        hideGen += 1
        lock.unlock()
        if Self.debug {
            let panelTL = toTopLeftCoords(panel.frame)
            let screen = screenTL(containing: CGPoint(x: panelTL.midX, y: panelTL.midY))
            ZSLog("DockHoverPreview: show gen=\(generation) target=\(targetLabel(target)) windows=\(windows.count) placement=\(placement) anchor=\(anchorTL) raw=\(target.frameTL) panelTL=\(panelTL) screen=\(screen.map { "\($0)" } ?? "nil")")
        }

        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
            self?.applyThumbnails(images, showGen: generation)
        }
    }

    private func applyThumbnails(_ images: [CGWindowID: NSImage], showGen generation: Int) {
        lock.lock()
        let live = generation == self.showGen && phase == .visible
        lock.unlock()
        guard live else { return }
        for (index, item) in model.items.enumerated() {
            if let image = images[item.id] {
                model.items[index].thumbnail = image
            }
        }
    }

    /// 主线程：懒创建面板
    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel()
        self.panel = panel
        return panel
    }

    /// 主线程：卡片剔除后重算面板尺寸（外框收缩，不留空白），
    /// 并同步保活/mouseDown 命中用的 panelFrameTL，避免旧的大框区域误判。
    private func refitPanelAfterClose() {
        guard panelShown, let panel else { return }
        panel.refit()
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.frame)
        lock.unlock()
    }

    // MARK: - 卡片动作（主线程）

    private func activate(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        lock.lock()
        let anchor = currentItemTL
        lock.unlock()
        let key = currentTarget.map { self.suppressKey(for: $0) }
        hidePanel(reason: "activate")
        if let anchor, let key {
            lock.lock()
            suppressKey = key
            suppressRegionTL = anchor
            lock.unlock()
        }
        // 复用切换器激活链：最小化先还原、跨 Space 自动切换、本 app 窗口走主线程
        WindowActivator.shared.focus(window: window)
    }

    private func suppressKey(for target: HoverTarget) -> String {
        switch target {
        case .app(let app, _):
            return "app:\(app.bundleIdentifier ?? "pid:\(app.processIdentifier)")"
        case .tile(let title, _):
            return "tile:\(title)"
        }
    }

    private func close(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        lock.lock()
        let gen = showGen
        lock.unlock()
        // 乐观更新：立即从面板剔除该卡片（缩略图走持久缓存预填，无闪烁）；
        // 单窗口 → 直接收起面板。随后校验刷新同步真实状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alive = gen == self.showGen && self.phase == .visible
            self.lock.unlock()
            guard alive else { return }
            let remaining = self.currentWindows.filter { $0.id != windowID }
            if remaining.isEmpty {
                self.hidePanel(reason: "last window closed")
            } else {
                self.currentWindows = remaining
                self.model.items = self.makeItems(remaining)
                self.refitPanelAfterClose()
            }
        }
        WindowOps.perform(.close, on: window) { [weak self] in
            self?.refreshAfterClose(showGen: gen)
        }
    }

    /// 关闭后刷新：重新枚举目标窗口；最后一个窗口被关掉时整个面板撤掉
    /// 关闭后的校验刷新（延时 400ms，等关窗动画结束）：只「剔除确认消失的窗口」，
    /// 不回加——枚举在关窗动画期间可能仍列出旧窗口，回加会让卡片闪回。
    private func refreshAfterClose(showGen generation: Int) {
        workQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lock.lock()
                guard self.phase == .visible, let target = self.currentTarget, generation == self.showGen else {
                    self.lock.unlock()
                    return
                }
                self.lock.unlock()
                self.workQueue.async { [weak self] in
                    let windows = self?.windows(for: target) ?? []
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let alive = generation == self.showGen && self.phase == .visible
                        self.lock.unlock()
                        guard alive else { return }
                        let remaining = self.currentWindows.filter { window in
                            windows.contains(where: { $0.id == window.id })
                        }
                        guard remaining.count != self.currentWindows.count else { return }
                        if remaining.isEmpty {
                            self.hidePanel(reason: "last window closed")
                        } else {
                            self.currentWindows = remaining
                            self.model.items = self.makeItems(remaining)
                            self.refitPanelAfterClose()
                            WindowThumbnailer.shared.fetchThumbnails(for: remaining) { [weak self] images in
                                self?.applyThumbnails(images, showGen: generation)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 面板定位

    /// 面板朝向：按 Dock 贴哪条边决定——底部 Dock 面板在上方，左侧 Dock 面板在右侧，右侧 Dock 在左侧。
    /// 不再用「缓存项 bbox 的横竖」判定：多显示器下 bbox 只代表其中一块屏的 Dock，
    /// 而且跨屏并集会横跨两屏，方向判断会直接错。
    private func placement() -> DockPreviewPanel.Placement {
        switch dockEdge() {
        case .bottom: return .above
        case .left: return .rightOf
        case .right: return .leftOf
        }
    }

    // MARK: - 键盘与全局隐藏触发

    /// visible 时任意按键（含 Esc）收起面板；事件不吞，不影响其他响应
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.isVisible() {
                self.hidePanel(reason: "keyDown \(event.keyCode)")
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 全局隐藏触发：Space 切换 / 锁屏睡眠 / 目标 app 或 Dock 退出 / 屏幕配置变化
    private func observeHideTriggers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "space changed")
                self?.dockLayoutMayHaveChanged()
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "sleep")
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "screens sleep")
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.bundleIdentifier == Self.dockBundleID {
                    self?.dockLayoutMayHaveChanged()
                }
                self?.hideIfTarget(app: app)
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
        ]
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hidePanel(reason: "screen config changed")
            self?.dockLayoutMayHaveChanged()
        }
    }

    /// 目标 app 退出时收起（tile 目标不跟踪 app 退出）
    private func hideIfTarget(app: NSRunningApplication) {
        guard let target = currentTarget else { return }
        switch target {
        case .app(let targetApp, _):
            if targetApp.processIdentifier == app.processIdentifier {
                hidePanel(reason: "target app quit")
            }
        case .tile:
            break
        }
    }

    // MARK: - Dock 项缓存（独立拷贝自 DockClickMinimizer 的探测逻辑，另含瓦片标题）

    /// Dock 布局变化（图标增删、切 Space、Dock 重启）时置缓存失效并防抖重建
    private func dockLayoutMayHaveChanged() {
        lock.lock()
        cacheInvalid = true
        lock.unlock()
        scheduleCacheRebuild()
    }

    /// trailing-edge 防抖：布局事件爆发时合并为一次重建
    private func scheduleCacheRebuild(delay: TimeInterval = 0.3) {
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildDockCache()
        }
        lock.lock()
        pendingCacheRebuild?.cancel()
        pendingCacheRebuild = work
        lock.unlock()
        cacheQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuildDockCache() {
        lock.lock()
        let enabled = SettingsStore.shared.dockPreviewEnabled && isRunning
        lock.unlock()
        guard enabled else { return }

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            scheduleCacheRebuild(delay: 2)
            return
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        // 注意:Dock 不通过 kAXWindowsAttribute 公开图标(实测返回空数组),
        // 必须从应用元素的直接子元素开始递归(与 DockClickMinimizer 的命中目标同源)
        guard let roots = copyAXElements(dockElement, kAXChildrenAttribute), !roots.isEmpty else {
            ZSLog("DockHoverPreview: cache rebuild retry (dock children unreadable)")
            scheduleCacheRebuild(delay: 2)
            return
        }

        var nextID = 0
        var items: [DockItem] = []
        var roles: [String: Int] = [:]
        for root in roots {
            collectDockItems(in: root, into: &items, nextID: &nextID, roles: &roles)
        }
        lock.lock()
        dockItems = items
        cacheInvalid = false
        lock.unlock()
        let top = roles.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        ZSLog("DockHoverPreview: cache rebuilt items=\(items.count) strip=\(bboxOfItems(items).map{"\($0)"} ?? "nil") roles=[\(top)]")
    }

    private func collectDockItems(in element: AXUIElement, into items: inout [DockItem], nextID: inout Int, roles: inout [String: Int]) {
        let roleName = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String? ?? "?"
        roles[roleName, default: 0] += 1
        if isDockItemElement(element),
           let point = axPoint(element, kAXPositionAttribute),
           let size = axSize(element, kAXSizeAttribute) {
            let app = appForDockItem(element)
            let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
            items.append(DockItem(id: nextID, frame: CGRect(origin: point, size: size), app: app, title: title))
            nextID += 1
        }
        if let children = copyAXElements(element, kAXChildrenAttribute) {
            for child in children {
                collectDockItems(in: child, into: &items, nextID: &nextID, roles: &roles)
            }
        }
    }

    // MARK: - AX 权威命中（独立拷贝自 DockClickMinimizer，扩展瓦片识别）

    /// 解析结果：
    /// - `notDockElement`：AX 正常但该点不是可识别 Dock 项（分隔符/空白等）。多显示器下
    ///   「这块屏的 Dock 不在 AX 树里」也落到这里，因此**允许**缓存（含跨屏投影）兜底，
    ///   但只在指针确实落在某个图标 frame 内时才认（见 resolveAndShow）。
    /// - `menuElement`：命中的是 Dock 右键菜单/菜单项，绝不能用缓存兜底（否则菜单悬在图标上会弹预览）。
    /// - `failed`：AX 调用本身偶发失败，用缓存身份兜底。
    private enum ResolveOutcome {
        case resolved(HoverTarget)
        case notDockElement
        case menuElement
        case failed
    }

    /// 问系统「该点上是什么元素」，向上找最近的 Dock 项；app 项与无 URL 项（瓦片候选）都返回
    private func resolveTarget(at point: CGPoint) -> ResolveOutcome {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let raw else { return .failed }
        var element = raw
        // 调试用：记录命中元素的角色链，多显示器排查「副屏 Dock 到底在不在 AX 里」直接看这条
        var chain: [String] = []
        for _ in 0..<Self.parentWalkDepth {
            if Self.debug {
                chain.append(copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String? ?? "?")
            }
            if isDockItemElement(element) || isAnyDockItemElement(element) {
                guard let pos = axPoint(element, kAXPositionAttribute),
                      let size = axSize(element, kAXSizeAttribute) else { return .failed }
                let frame = CGRect(origin: pos, size: size)
                if let app = appForDockItem(element) {
                    return .resolved(.app(app, frameTL: frame))
                }
                // 无 URL 项：最小化窗口瓦片候选（堆栈/废纸篓标题通常反查不到窗口，自然不弹）
                let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
                guard !title.isEmpty else { return .notDockElement }
                return .resolved(.tile(title: title, frameTL: frame))
            }
            // 命中 Dock 右键菜单/菜单项：不视为图标悬停
            if isMenuElement(element) {
                if Self.debug { ZSLog("DockHoverPreview: hit dock menu, chain=\(chain.joined(separator: "<-"))") }
                return .menuElement
            }
            guard let parent = axParent(element) else { break }
            element = parent
        }
        if Self.debug { ZSLog("DockHoverPreview: not dock item, chain=\(chain.joined(separator: "<-"))") }
        return .notDockElement
    }

    /// 菜单类元素：Dock 图标右键弹出的菜单/菜单项
    private func isMenuElement(_ element: AXUIElement) -> Bool {
        let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?
        let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?
        switch role ?? subrole {
        case kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole:
            return true
        default:
            return false
        }
    }

    private func isDockItemElement(_ element: AXUIElement) -> Bool {
        if let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?,
           role == Self.dockItemRole {
            return true
        }
        if let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?,
           subrole == Self.dockItemRole {
            return true
        }
        return false
    }

    /// 通用 Dock 项角色（AXDockItem）：只用于权威命中，不参与缓存收集——
    /// 缓存里混进分隔符/堆栈会污染条带 bbox 与项 id。
    private func isAnyDockItemElement(_ element: AXUIElement) -> Bool {
        if let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?,
           role == Self.dockItemRoleLoose {
            return true
        }
        return false
    }

    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let raw else { return nil }
        // AX 元素的父元素恒为 AXUIElement，强制桥接
        let parent: AXUIElement = raw as! AXUIElement
        return parent
    }

    /// Dock 项 → 对应运行中的应用。优先 kAXURL（.app file URL → bundleID），
    /// 无 URL 的项（Launchpad/Trash/窗口图标等）按标题兜底匹配。
    private func appForDockItem(_ element: AXUIElement) -> NSRunningApplication? {
        if let urlRaw = copyAXValue(element, kAXURLAttribute, as: NSURL.self),
           let bundle = Bundle(url: urlRaw as URL),
           let bundleID = bundle.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? {
            return runningApp(named: title)
        }
        return nil
    }

    private func runningApp(named title: String) -> NSRunningApplication? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            let displayName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let executableName = app.executableURL?.deletingPathExtension().lastPathComponent.lowercased()
            return displayName == normalized || executableName == normalized
        }
    }

    // MARK: - 坐标（CGEvent/AX/CGWindow 均为「主屏左上原点」的点坐标）

    private func topLeftFrame(of screen: NSScreen) -> CGRect {
        toTopLeftCoords(screen.frame)
    }

    /// Cocoa 矩形（左下原点）→ 左上原点全局坐标。
    /// 翻转基准必须是**主屏**（Cocoa 原点所在屏）的 maxY：CGEvent/AX 的全局原点就是主屏左上角。
    /// 用 `union.maxY` 只在「主屏恰好在所有屏最上方」时才对，外接屏摆到主屏上方会整体偏移一块屏高。
    private func toTopLeftCoords(_ rect: CGRect) -> CGRect {
        toTopLeftCoords(rect, flipMaxY: flipMaxY)
    }

    private func toTopLeftCoords(_ rect: CGRect, flipMaxY flip: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: flip - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 坐标翻转基准（主屏 maxY）；取不到主屏时退回所有屏的并集
    private var flipMaxY: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.minX == 0 && $0.frame.minY == 0 }) {
            return primary.frame.maxY
        }
        return NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
    }

    /// Dock 条带 bbox（缓存项整体范围，AX 左上原点全局坐标）；缓存无效时 nil。
    /// **只代表 AX 树里那一个 Dock**（多显示器时可能是另一块屏的），不参与触发判定。
    private func dockStripTL() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        return bboxOfItems(dockItems)
    }

    private func bboxOfItems(_ items: [DockItem]) -> CGRect? {
        var bbox = CGRect.null
        for item in items { bbox = bbox.union(item.frame) }
        return bbox.isNull ? nil : bbox
    }

    // MARK: - Dock 边缘带（多显示器）

    /// Dock 贴在屏幕的哪条边（系统级设置，与具体是哪块屏无关）
    private enum DockEdge { case bottom, left, right }

    /// 判断 Dock 朝向。顺序很重要：
    /// 1. **Dock 自己的全局偏好** `com.apple.dock orientation`——最可靠。自动隐藏的侧边 Dock
    ///    在 AX 里给的是退化坐标（实测 14 个项全是 16×0、位置 (-10,0)），拿它判方向会误判成底部，
    ///    面板就会跑到图标上方并横排；
    /// 2. `frame − visibleFrame` 的 inset：Dock 未自动隐藏时能直接量到；
    /// 3. 最后才是缓存条带的排布方向（自动隐藏的**底部** Dock 坐标仍然有效）。
    private func dockEdge() -> DockEdge {
        if let raw = Self.dockOrientationRaw() {
            switch raw {
            case "left": return .left
            case "right": return .right
            case "bottom": return .bottom
            default: break
            }
        }
        let flip = flipMaxY
        for screen in NSScreen.screens {
            let f = toTopLeftCoords(screen.frame, flipMaxY: flip)
            let v = toTopLeftCoords(screen.visibleFrame, flipMaxY: flip)
            if v.minX - f.minX > Self.dockInsetThreshold { return .left }
            if f.maxX - v.maxX > Self.dockInsetThreshold { return .right }
            if f.maxY - v.maxY > Self.dockInsetThreshold { return .bottom }
        }
        if let strip = dockStripTL(), !isDegenerateDockFrame(strip) {
            if strip.width >= strip.height * 2 { return .bottom }
            if let screen = nearestScreenTL(to: strip) {
                return strip.midX < screen.midX ? .left : .right
            }
        }
        return .bottom
    }

    /// AX 在「自动隐藏的侧边 Dock」上会给出退化坐标（实测所有项都是 16×0、位置 (-10,0)），
    /// 这类 frame 不能用于方向/跨度/锚点计算，必须按「指针 + 边缘带」重建。
    private func isDegenerateDockFrame(_ rect: CGRect) -> Bool {
        rect.width < 8 || rect.height < 8
    }

    /// **每块屏**的 Dock 边缘带（AX 左上原点全局坐标）。
    /// 多显示器下每块屏都有自己的 Dock，而 Dock 的 AX 树只暴露其中一块屏的图标
    /// （实测 kAXWindows=0、应用子元素只有一个 AXList，且跟着主屏走），
    /// 所以触发/闸门一律按「屏幕边缘 + Dock 朝向」推导，不依赖 AX 给的任何 Dock 框。
    /// 厚度：优先用 `frame − visibleFrame` 的实测值（Dock 可见时就是真实厚度），
    /// 自动隐藏时为 0，用常量兜底（Dock 展开后占的就是这条边）。
    private func dockBandZonesTL() -> [CGRect] {
        let edge = dockEdge()
        let flip = flipMaxY
        // Dock 内容在各屏完全一致（同样的图标、同样的图标尺寸），缓存条带的长边就是 Dock 的跨度；
        // 用它把带收窄到 Dock 实际占的范围，避免「整条屏幕边」都参与触发（悬停窗口底边也会走
        // 一次权威命中）。放大时 Dock 会横向撑开约 30%，留 1.2 倍余量。
        // 退化坐标（自动隐藏的侧边 Dock）不能拿来定跨度，直接铺满整条边
        let strip = dockStripTL().flatMap { isDegenerateDockFrame($0) ? nil : $0 }
        let horizontalSpan = strip.flatMap { $0.width >= $0.height * 2 ? $0.width : nil }
        let verticalSpan = strip.flatMap { $0.height > $0.width * 2 ? $0.height : nil }
        return NSScreen.screens.map { screen in
            let f = toTopLeftCoords(screen.frame, flipMaxY: flip)
            let v = toTopLeftCoords(screen.visibleFrame, flipMaxY: flip)
            switch edge {
            case .bottom:
                let measured = f.maxY - v.maxY
                let thickness = min(max(measured, Self.bottomBandMinThickness), f.height / 3)
                let span = min(max((horizontalSpan ?? f.width) * 1.2, 240), f.width)
                return CGRect(x: f.midX - span / 2, y: f.maxY - thickness, width: span, height: thickness)
            case .left:
                let measured = v.minX - f.minX
                let thickness = min(max(measured, Self.sideBandMinThickness), f.width / 3)
                let span = min(max((verticalSpan ?? f.height) * 1.2, 240), f.height)
                return CGRect(x: f.minX, y: f.midY - span / 2, width: thickness, height: span)
            case .right:
                let measured = f.maxX - v.maxX
                let thickness = min(max(measured, Self.sideBandMinThickness), f.width / 3)
                let span = min(max((verticalSpan ?? f.height) * 1.2, 240), f.height)
                return CGRect(x: f.maxX - thickness, y: f.midY - span / 2, width: thickness, height: span)
            }
        }
    }

    /// AX 坐标退化时（自动隐藏的侧边 Dock：所有项都是 16×0 挤在 (-10,0)），
    /// 按「指针 + 该屏 Dock 边缘带」重建一个可信的图标锚点，保证面板贴在图标旁边而不是屏幕角落。
    private func sanitizedAnchor(_ frame: CGRect, at point: CGPoint) -> CGRect {
        guard isDegenerateDockFrame(frame) else { return frame }
        let margin = Self.stripTriggerMargin
        guard let band = dockBandZonesTL().first(where: {
            $0.insetBy(dx: -margin, dy: -margin).contains(point)
        }) else { return frame }
        switch dockEdge() {
        case .bottom:
            let width = min(max(frame.width, 42), band.width)
            return CGRect(x: point.x - width / 2, y: band.minY, width: width, height: band.height)
        case .left, .right:
            let height = min(max(frame.height, 42), band.height)
            return CGRect(x: band.minX, y: point.y - height / 2, width: band.width, height: height)
        }
    }

    /// 指针是否落在**任意一块屏**的 Dock 边缘带内（外扩 margin）
    private func isInDockZone(_ point: CGPoint, margin: CGFloat) -> Bool {
        for band in dockBandZonesTL() where band.insetBy(dx: -margin, dy: -margin).contains(point) {
            return true
        }
        return false
    }

    /// 指针是否在 Dock 边缘带附近：作为挂起权威命中的触发条件。
    /// 对齐 DockClickMinimizer 的思路：只有真正接近 Dock 本体才参与判定，
    /// 而不是「靠近屏幕任意边缘」——后者会导致从上方接近时过早触发、在屏幕中部误触发。
    private func isNearDockStrip(_ point: CGPoint) -> Bool {
        isInDockZone(point, margin: Self.stripTriggerMargin)
    }

    /// 指针是否贴近**所在屏** Dock 那条边（整条边，外扩 margin）。
    /// 边缘带的跨度是从缓存条带推出来的——缓存可能描述的是另一块屏（Dock 的 AX 树只暴露
    /// 一块屏，见 DEV-058），跨度未必盖得住这块屏的 Dock；这里只按屏幕边兜底，
    /// 保证副屏「移到隔壁图标」不会被漏判成「离开 Dock」。
    private func isNearDockEdge(_ point: CGPoint, margin: CGFloat) -> Bool {
        let edge = dockEdge()
        for screen in NSScreen.screens {
            let f = toTopLeftCoords(screen.frame)
            guard f.insetBy(dx: -margin, dy: -margin).contains(point) else { continue }
            switch edge {
            case .bottom: return point.y >= f.maxY - margin
            case .left: return point.x <= f.minX + margin
            case .right: return point.x >= f.maxX - margin
            }
        }
        return false
    }

    /// 与 rect 最近的屏幕（左上原点；已相交时距离为 0）
    private func nearestScreenTL(to rect: CGRect) -> CGRect? {
        var best: (frame: CGRect, distance: CGFloat)?
        for screen in NSScreen.screens {
            let frame = topLeftFrame(of: screen)
            var distance: CGFloat = 0
            if frame.intersection(rect).isNull {
                let dx = max(0, max(frame.minX - rect.maxX, rect.minX - frame.maxX))
                let dy = max(0, max(frame.minY - rect.maxY, rect.minY - frame.maxY))
                distance = hypot(dx, dy)
            }
            if best == nil || distance < best!.distance { best = (frame, distance) }
        }
        return best?.frame
    }

    // MARK: - AX 辅助（与 DockClickMinimizer 同款）

    private func copyAXValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

    private func copyAXElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
