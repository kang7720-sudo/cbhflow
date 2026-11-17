import AppKit
import CoreGraphics
import Darwin

/// 窗口缩略图抓取：SkyLight 私有 API `CGSHWCaptureWindowList`（运行时 dlsym 桥接）。
/// - 能截取最小化/离屏窗口（公开 API ScreenCaptureKit 截不到最小化窗口）。
/// - 全程后台单队列执行，逐窗口调用（该 API 实际只认窗口列表第一个，批量传会丢结果）。
/// - 按 CGWindowID 缓存（TTL ≈ 10s）；同一窗口 800ms 内不重复抓。
/// - 抓到一张就立刻缩放到卡片所需尺寸，不批量持有全分辨率图（避免抓取峰值上百 MB）。
/// - 缓存用 NSCache（按像素字节计 cost，总量有界），长时间运行不会无限增长。
/// - 抓取失败/API 缺失时静默降级（面板显示 app 图标），不弹错不崩溃。
final class WindowThumbnailer {
    static let shared = WindowThumbnailer()

    private final class CachedThumbnail {
        let image: NSImage
        let date: Date

        init(image: NSImage, date: Date) {
            self.image = image
            self.date = date
        }
    }

    private let queue = DispatchQueue(label: "zeroflow.window-thumbnailer", qos: .userInitiated)
    private let lock = NSLock()
    private let cache = NSCache<NSNumber, CachedThumbnail>()
    private var lastAttempt: [CGWindowID: Date] = [:]
    private static var didLogBridgeFailure = false

    // AltTab 实际使用的选项位（旧版头文件的 0x04|0x10|0x20 已失效，传 0x34 会返回空）：
    // ignoreGlobalClipShape=1<<11, bestResolution=1<<8, fullSize=1<<19
    private static let captureOptions: Int32 = (1 << 11) | (1 << 8) | (1 << 19)
    private let cacheTTL: TimeInterval = 10
    private let captureThrottle: TimeInterval = 0.8
    /// 卡片实际显示宽度 148~168pt，2x 屏最多 336px；168 足够且比 320 省 4 倍像素
    private static let maxThumbSide: CGFloat = 168
    /// 缩略图缓存上限：按像素字节计 cost，超出即淘汰（长时间运行内存有界）
    private static let cacheCostLimit = 8 * 1024 * 1024
    private static let cacheCountLimit = 40

    private init() {
        cache.totalCostLimit = Self.cacheCostLimit
        cache.countLimit = Self.cacheCountLimit
    }

    private struct CaptureBridge {
        let mainConn: @convention(c) () -> Int32
        let captureList: @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, Int32) -> Unmanaged<CFArray>?
    }

    private static let bridge: CaptureBridge? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            ZSLog("WindowThumbnailer: dlopen SkyLight failed — thumbnails will fall back to app icons")
            return nil
        }
        guard let connSym = dlsym(handle, "CGSMainConnectionID"),
              let captureSym = dlsym(handle, "CGSHWCaptureWindowList") else {
            ZSLog("WindowThumbnailer: SkyLight symbol missing — thumbnails will fall back to app icons")
            return nil
        }
        let mainConn = unsafeBitCast(connSym, to: (@convention(c) () -> Int32).self)
        let captureList = unsafeBitCast(captureSym, to: (@convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, Int32) -> Unmanaged<CFArray>?).self)
        return CaptureBridge(mainConn: mainConn, captureList: captureList)
    }()

    func invalidateCache() {
        lock.lock()
        cache.removeAllObjects()
        lastAttempt.removeAll()
        lock.unlock()
    }

    /// 后台抓取一批窗口缩略图，完成后在主队列回调 `[CGWindowID: NSImage]`（只含抓到的）。
    func fetchThumbnails(for windows: [SwitcherWindow],
                         completion: @escaping ([CGWindowID: NSImage]) -> Void) {
        queue.async { [self] in
            let result = captureAll(windows: windows)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// 同步读取缓存里的缩略图（不触发抓取、不刷新 TTL）：
    /// 面板先用旧图预填，避免 WindowThumbnailer 节流/TTL 期间出现空占位。
    func cachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        let key = NSNumber(value: windowID)
        guard let entry = cache.object(forKey: key),
              Date().timeIntervalSince(entry.date) < cacheTTL else { return nil }
        return entry.image
    }

    private func captureAll(windows: [SwitcherWindow]) -> [CGWindowID: NSImage] {
        guard let bridge = Self.bridge else {
            if !Self.didLogBridgeFailure {
                Self.didLogBridgeFailure = true
                ZSLog("WindowThumbnailer: SkyLight unavailable, logging once and downgrading to icons")
            }
            return [:]
        }
        let now = Date()
        var out: [CGWindowID: NSImage] = [:]
        var missing: [(id: CGWindowID, bounds: CGRect)] = []

        lock.lock()
        for w in windows {
            let key = NSNumber(value: w.id)
            if let entry = cache.object(forKey: key), now.timeIntervalSince(entry.date) < cacheTTL {
                out[w.id] = entry.image
            } else if let last = lastAttempt[w.id], now.timeIntervalSince(last) < captureThrottle {
                // 节流：不在短时间内重复抓同一窗口
            } else {
                lastAttempt[w.id] = now
                missing.append((w.id, w.bounds))
            }
        }
        lock.unlock()

        guard !missing.isEmpty else { return out }

        let cid = bridge.mainConn()
        for target in missing {
            // 逐张抓取后立刻缩放并释放原图：批量持有全分辨率 CGImage 会让峰值冲到上百 MB
            autoreleasepool {
                var id = target.id
                guard let array = bridge.captureList(cid, &id, 1, Self.captureOptions)?.takeRetainedValue() as? [CGImage],
                      let image = array.first else { return }
                let thumb = resized(image, bounds: target.bounds)
                let cost = Int(thumb.size.width * 2 * thumb.size.height * 2 * 4)
                lock.lock()
                cache.setObject(CachedThumbnail(image: thumb, date: now), forKey: NSNumber(value: target.id), cost: cost)
                out[target.id] = thumb
                lock.unlock()
            }
        }

        // 节流表只增不删会缓慢膨胀，按 TTL 清理
        lock.lock()
        lastAttempt = lastAttempt.filter { now.timeIntervalSince($0.value) < cacheTTL }
        lock.unlock()
        return out
    }

    /// 按窗口宽高比把原始 CGImage 缩放到缩略图尺寸（2x 物理像素，控制驻留内存）
    private func resized(_ image: CGImage, bounds: CGRect) -> NSImage {
        let aspect = bounds.width > 0 && bounds.height > 0 ? bounds.height / bounds.width : 10.0 / 16.0
        var w = Self.maxThumbSide
        var h = Self.maxThumbSide * aspect
        if h > Self.maxThumbSide {
            h = Self.maxThumbSide
            w = Self.maxThumbSide / aspect
        }
        let pxW = max(1, Int(w * 2))
        let pxH = max(1, Int(h * 2))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return NSImage(cgImage: image, size: NSSize(width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
        guard let out = ctx.makeImage() else {
            return NSImage(cgImage: image, size: NSSize(width: w, height: h))
        }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }
}