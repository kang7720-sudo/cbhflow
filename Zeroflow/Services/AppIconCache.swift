import AppKit

/// App 图标缓存：`NSRunningApplication.icon` 自带 16–2048px 的整套表示（单张 TIFF 可达 70MB），
/// 而卡片/面板最多只显示 52pt。这里统一降采样成 128×128 单表示位图再缓存，
/// 避免整套大图常驻，也省掉每次绘制时解析几十个表示的开销。
final class AppIconCache {
    static let shared = AppIconCache()

    /// 128px 覆盖 52pt 卡片在 2x 屏的 104px 需求，单张约 64KB
    private static let pixelSide = 128
    private static let countLimit = 64

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = Self.countLimit
    }

    func icon(for app: NSRunningApplication) -> NSImage? {
        let key = (app.bundleIdentifier ?? "pid:\(app.processIdentifier)") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let icon = app.icon else { return nil }
        guard let downsampled = Self.downsample(icon) else { return icon }
        cache.setObject(downsampled, forKey: key)
        return downsampled
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return nil
        }
        return icon(for: app)
    }

    /// 画成固定边长单表示位图（约 64KB）；绘制完原图即释放
    private static func downsample(_ icon: NSImage) -> NSImage? {
        let side = pixelSide
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side,
                                         pixelsHigh: side,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        image.addRepresentation(rep)
        return image
    }
}
