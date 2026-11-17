import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板历史存储：去重置顶、按设置裁剪条数、JSON 持久化到 Application Support。
///
/// 图片分三层落盘：原图 `clipboard-images/<id>.png`（粘贴用），派生图
/// `clipboard-images/derived/<id>.thumb.jpg`（列表行，≤96px）与 `<id>.preview.jpg`（预览，≤1024px）。
/// 列表/预览只读派生图这种小文件，**不再为大图做显示级解码**——原因见 DEV-054。
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    /// 最新在前
    @Published private(set) var items: [ClipboardItem] = []

    /// 单条文本上限（UTF-8 字节）
    static let maxTextBytes = 256 * 1024
    /// 单张图片 PNG 上限
    static let maxImageBytes = 20 * 1024 * 1024

    /// 列表行缩略图像素上限（22pt 行 @3x ≈ 66px，留余量）
    static let thumbnailPixelSize = 96
    /// 预览图像素上限（预览列 460pt @2x ≈ 920px）
    static let previewPixelSize = 1024

    private let fileManager = FileManager.default
    private let imagesDirectory: URL
    private let derivedDirectory: URL
    private let historyFile: URL
    /// 编码/写盘放串行后台队列，避免大历史阻塞主线程；顺序由队列保证
    private let ioQueue = DispatchQueue(label: "zeroflow.clipboard-history.io", qos: .utility)

    /// 内存里只保留「面板打开期间」用到的小图：缩略图是 96px 小 JPEG 的解码结果（≈37KB/张），
    /// 预览只留当前一张。面板一关就 `purgeMemoryCaches()` 整体清空，关窗后不常驻解码位图。
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()

    /// 历史在后台解码；完成前到达的新条目先缓冲，避免被随后落地的旧快照覆盖
    private var isLoaded = false
    private var pendingItems: [ClipboardItem] = []
    /// 清空/重置时递增，作废在途加载结果
    private var loadGeneration = 0

    private init() {
        thumbnailCache.totalCostLimit = 3 * 1024 * 1024
        previewCache.totalCostLimit = 8 * 1024 * 1024
        // 预览同一时刻只展示一张，多留没意义，反而把 2~3MB 的解码位图钉在内存里
        previewCache.countLimit = 1
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let baseDirectory = support.appendingPathComponent("zeroflow", isDirectory: true)
        imagesDirectory = baseDirectory.appendingPathComponent("clipboard-images", isDirectory: true)
        derivedDirectory = imagesDirectory.appendingPathComponent("derived", isDirectory: true)
        historyFile = baseDirectory.appendingPathComponent("clipboard-history.json")
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: derivedDirectory, withIntermediateDirectories: true)
        loadInBackground()
    }

    // MARK: - 写入

    @discardableResult
    func addText(_ text: String, sourceApp: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let bytes = text.utf8.count
        guard bytes <= Self.maxTextBytes else { return false }
        insert(ClipboardItem(id: UUID(),
                             kind: .text,
                             text: text,
                             imageFileName: nil,
                             pixelWidth: 0,
                             pixelHeight: 0,
                             byteCount: bytes,
                             sourceAppName: sourceApp,
                             createdAt: Date(),
                             contentHash: Self.hash(Data(text.utf8))))
        return true
    }

    @discardableResult
    func addImage(pngData: Data, pixelSize: CGSize, sourceApp: String) -> Bool {
        guard !pngData.isEmpty, pngData.count <= Self.maxImageBytes else { return false }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            ZSLog("clipboard: write image failed \(error)")
            return false
        }
        // 派生图（列表缩略图 + 预览图）在 ioQueue 里生成，避免复制瞬间卡主线程
        let thumbURL = derivedDirectory.appendingPathComponent(Self.derivedName(fileName, kind: "thumb"))
        let previewURL = derivedDirectory.appendingPathComponent(Self.derivedName(fileName, kind: "preview"))
        ioQueue.async {
            Self.writeDerivedImages(from: CGImageSourceCreateWithData(pngData as CFData, nil),
                                    thumbnailTo: thumbURL,
                                    previewTo: previewURL)
        }
        insert(ClipboardItem(id: id,
                             kind: .image,
                             text: "",
                             imageFileName: fileName,
                             pixelWidth: Int(pixelSize.width.rounded()),
                             pixelHeight: Int(pixelSize.height.rounded()),
                             byteCount: pngData.count,
                             sourceAppName: sourceApp,
                             createdAt: Date(),
                             contentHash: Self.hash(pngData)))
        return true
    }

    // MARK: - 读取

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    func pngData(for item: ClipboardItem) -> Data? {
        guard let url = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 列表行缩略图：只读 ≤96px 的小 JPEG；旧条目没有派生图时现场补一份
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        decodedImage(for: item,
                     derivedURL: thumbnailURL(for: item),
                     cache: thumbnailCache,
                     keyPrefix: "thumb:")
    }

    /// 预览图：只读 ≤1024px 的小 JPEG
    func previewImage(for item: ClipboardItem) -> NSImage? {
        decodedImage(for: item,
                     derivedURL: previewURL(for: item),
                     cache: previewCache,
                     keyPrefix: "preview:")
    }

    /// 面板收起时调用：丢掉所有解码后的位图，关窗后不再常驻
    func purgeMemoryCaches() {
        thumbnailCache.removeAllObjects()
        previewCache.removeAllObjects()
    }

    private func decodedImage(for item: ClipboardItem,
                              derivedURL: URL?,
                              cache: NSCache<NSString, NSImage>,
                              keyPrefix: String) -> NSImage? {
        guard let imageURL = imageURL(for: item), let derivedURL else { return nil }
        let key = Self.cacheKey(prefix: keyPrefix, name: imageURL.lastPathComponent)
        if let cached = cache.object(forKey: key) { return cached }
        if !fileManager.fileExists(atPath: derivedURL.path) {
            ensureDerivedImages(for: item, imageURL: imageURL)
        }
        guard let cgImage = Self.decodeImage(at: derivedURL) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    private func thumbnailURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return derivedDirectory.appendingPathComponent(Self.derivedName(name, kind: "thumb"))
    }

    private func previewURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return derivedDirectory.appendingPathComponent(Self.derivedName(name, kind: "preview"))
    }

    private static func derivedName(_ imageFileName: String, kind: String) -> String {
        "\((imageFileName as NSString).deletingPathExtension).\(kind).jpg"
    }

    private static func cacheKey(prefix: String, name: String) -> NSString {
        "\(prefix)\(name)" as NSString
    }

    /// 补齐派生图（升级前的老条目、或上次写盘失败）：从原图解码一次，同时写出缩略图与预览图
    private func ensureDerivedImages(for item: ClipboardItem, imageURL: URL) {
        guard let thumbURL = thumbnailURL(for: item),
              let previewURL = previewURL(for: item),
              !fileManager.fileExists(atPath: thumbURL.path)
                || !fileManager.fileExists(atPath: previewURL.path) else { return }
        Self.writeDerivedImages(from: CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                                thumbnailTo: thumbURL,
                                previewTo: previewURL)
    }

    // MARK: - 派生图（不要用 CGImageSourceCreateThumbnailAtIndex 出大尺寸）

    private static func writeDerivedImages(from source: CGImageSource?,
                                           thumbnailTo thumbURL: URL,
                                           previewTo previewURL: URL) {
        guard let source,
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if let thumb = resized(full, maxPixelSize: thumbnailPixelSize) {
            writeJPEG(thumb, to: thumbURL, quality: 0.75)
        }
        if let preview = resized(full, maxPixelSize: previewPixelSize) {
            writeJPEG(preview, to: previewURL, quality: 0.8)
        }
    }

    /// 全解码后按长边缩放重绘：比 `CGImageSourceCreateThumbnailAtIndex` 省一大截常驻内存
    /// （DEV-054：后者出 1024px 图每次约 3MB 脏页不回收，30 次 +93MB；重绘 30 次只涨 3MB）。
    private static func resized(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1.0, Double(maxPixelSize) / Double(longEdge))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        // JPEG 没有 alpha：先铺白底，透明 PNG（图标、切图）才不会变成黑块
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 读一张已经足够小的图（≤1024px 的 JPEG），整张解码即可
    private static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            ZSLog("clipboard: write derived image failed \(url.lastPathComponent)")
            return
        }
    }

    // MARK: - 维护

    /// 按当前「最多保存条数」裁剪（设置页改条数后调用）
    func trimToLimit() {
        guard isLoaded else { return }
        trimToLimit(persist: true)
    }

    func clear() {
        loadGeneration += 1
        isLoaded = true
        pendingItems.removeAll()
        for item in items { removeImageFile(for: item) }
        items.removeAll()
        purgeMemoryCaches()
        persist()
    }

    // MARK: - 内部

    private func insert(_ item: ClipboardItem) {
        guard isLoaded else {
            pendingItems.insert(item, at: 0)
            return
        }
        // 同一内容再复制只置顶：先移除旧条目（连同其图片文件）
        let duplicates = items.filter { $0.contentHash == item.contentHash && $0.kind == item.kind }
        if !duplicates.isEmpty {
            items.removeAll { duplicate in duplicates.contains { $0.id == duplicate.id } }
            for duplicate in duplicates { removeImageFile(for: duplicate) }
        }
        items.insert(item, at: 0)
        trimToLimit(persist: false)
        persist()
    }

    private func trimToLimit(persist shouldPersist: Bool) {
        let limit = max(1, min(1000, SettingsStore.shared.clipboardMaxItems))
        guard items.count > limit else { return }
        let removed = items.suffix(items.count - limit)
        items.removeLast(items.count - limit)
        for item in removed { removeImageFile(for: item) }
        if shouldPersist { persist() }
    }

    private func removeImageFile(for item: ClipboardItem) {
        guard let url = imageURL(for: item) else { return }
        thumbnailCache.removeObject(forKey: Self.cacheKey(prefix: "thumb:", name: url.lastPathComponent))
        previewCache.removeObject(forKey: Self.cacheKey(prefix: "preview:", name: url.lastPathComponent))
        try? fileManager.removeItem(at: url)
        for derivedURL in [thumbnailURL(for: item), previewURL(for: item)].compactMap({ $0 }) {
            try? fileManager.removeItem(at: derivedURL)
        }
    }

    private func loadInBackground() {
        let generation = loadGeneration
        let url = historyFile
        ioQueue.async { [weak self] in
            let stored = Self.decodeHistory(at: url)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.applyLoaded(stored)
            }
        }
    }

    private static func decodeHistory(at url: URL) -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([ClipboardItem].self, from: data) else {
            ZSLog("clipboard: decode history failed")
            return []
        }
        return stored
    }

    private func applyLoaded(_ stored: [ClipboardItem]) {
        isLoaded = true
        let pending = pendingItems
        pendingItems = []
        let pendingKeys = Set(pending.map { "\($0.kind)-\($0.contentHash)" })
        items = pending + stored.filter { !pendingKeys.contains("\($0.kind)-\($0.contentHash)") }
        trimToLimit(persist: !pending.isEmpty)
        warmMissingDerivedImages()
    }

    /// 升级前的老条目只有原图，没有派生图：启动后在后台给最近若干条补齐，
    /// 免得首次打开面板时为十几张大 PNG 现场解码而卡一下。新条目在写入时已带派生图。
    private func warmMissingDerivedImages(limit: Int = 24) {
        let targets: [(URL, URL, URL)] = items.prefix(limit).compactMap { item in
            guard let imageURL = imageURL(for: item),
                  let thumbURL = thumbnailURL(for: item),
                  let previewURL = previewURL(for: item),
                  !fileManager.fileExists(atPath: thumbURL.path)
                    || !fileManager.fileExists(atPath: previewURL.path) else { return nil }
            return (imageURL, thumbURL, previewURL)
        }
        guard !targets.isEmpty else { return }
        ioQueue.async {
            for (imageURL, thumbURL, previewURL) in targets {
                guard !FileManager.default.fileExists(atPath: thumbURL.path)
                        || !FileManager.default.fileExists(atPath: previewURL.path) else { continue }
                Self.writeDerivedImages(from: CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                                        thumbnailTo: thumbURL,
                                        previewTo: previewURL)
            }
            ZSLog("clipboard: warmed \(targets.count) derived images")
        }
    }

    private func persist() {
        let snapshot = items
        let url = historyFile
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                ZSLog("clipboard: persist failed \(error)")
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
