import AppKit
import HeliarcCore
import OSLog
import ScreenCaptureKit

final class ThumbnailService {
    private struct CaptureRequest {
        let tab: BrowserTab
        let key: String
        let isCurrent: () -> Bool
        let completion: (NSImage?) -> Void
    }

    private let logger = Logger(subsystem: "build.robin.heliarc", category: "thumbnails")
    private let images = NSCache<NSString, NSImage>()
    private let ioQueue = DispatchQueue(label: "build.robin.heliarc.thumbnail-cache", qos: .utility)
    private let cacheDirectory: URL
    private var limiter = CaptureLimiter<String>()
    private let captureCooldown: TimeInterval = 3
    private let maxDiskBytes = 8 * 1_024 * 1_024

    init() {
        images.countLimit = 12
        images.totalCostLimit = 4 * 1_024 * 1_024
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("build.robin.heliarc", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func load(_ tabs: [BrowserTab], completion: @escaping ([String: NSImage]) -> Void) {
        ioQueue.async {
            var loaded: [String: NSImage] = [:]
            for tab in tabs {
                let key = self.cacheKey(for: tab)
                if let cached = self.images.object(forKey: key as NSString) {
                    loaded[tab.id] = cached
                    continue
                }
                let url = self.cacheDirectory.appendingPathComponent("\(key).jpg")
                guard let image = NSImage(contentsOf: url) else { continue }
                self.images.setObject(image, forKey: key as NSString, cost: self.cost(of: image))
                loaded[tab.id] = image
            }
            DispatchQueue.main.async { completion(loaded) }
        }
    }

    func capture(
        _ tab: BrowserTab,
        isCurrent: @escaping () -> Bool,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard hasPermission else {
            completion(nil)
            return
        }
        let key = cacheKey(for: tab)
        guard limiter.begin(key, at: Date(), cooldown: captureCooldown) else {
            completion(nil)
            return
        }
        let request = CaptureRequest(
            tab: tab,
            key: key,
            isCurrent: isCurrent,
            completion: completion
        )
        startCapture(request)
    }

    private func startCapture(_ request: CaptureRequest) {
        let started = CFAbsoluteTimeGetCurrent()
        let targetWindowID = frontmostHeliumWindowID()

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard error == nil, let content,
                  let window = content.windows.first(where: {
                      $0.windowID == targetWindowID
                          || (targetWindowID == nil
                              && $0.owningApplication?.bundleIdentifier == HeliumBridge.bundleID
                              && $0.windowLayer == 0
                              && $0.isOnScreen)
                  }) else {
                DispatchQueue.main.async {
                    self.finishCapture(request, image: nil)
                }
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = 480
            let aspectHeight = Int(480 * window.frame.height / max(window.frame.width, 1))
            configuration.height = max(270, min(360, aspectHeight))
            configuration.queueDepth = 1
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [self] image, error in
                guard error == nil, let image else {
                    DispatchQueue.main.async {
                        self.finishCapture(request, image: nil)
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard request.isCurrent() else {
                        self.finishCapture(request, image: nil, captured: false)
                        return
                    }
                    self.store(image, for: request.tab)
                    let thumbnail = NSImage(cgImage: image, size: .zero)
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    self.logger.debug("Captured thumbnail in \(elapsed, privacy: .public) ms")
                    self.finishCapture(request, image: thumbnail, captured: true)
                }
            }
        }
    }

    private func finishCapture(_ request: CaptureRequest, image: NSImage?, captured: Bool = false) {
        limiter.finish(request.key, at: Date(), captured: captured)
        request.completion(image)
    }

    private func store(_ image: CGImage, for tab: BrowserTab) {
        let key = cacheKey(for: tab)
        let thumbnail = NSImage(cgImage: image, size: .zero)
        images.setObject(thumbnail, forKey: key as NSString, cost: image.width * image.height * 4)
        ioQueue.async {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.62]) else { return }
            let url = self.cacheDirectory.appendingPathComponent("\(key).jpg")
            try? data.write(to: url, options: .atomic)
            self.pruneDiskCache()
        }
    }

    private func cacheKey(for tab: BrowserTab) -> String {
        CacheKey.thumbnail(tabID: tab.id, url: tab.url)
    }

    private func cost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 256 * 1_024 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }

    private func pruneDiskCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = files.map { url -> CacheEntry in
            let values = try? url.resourceValues(forKeys: keys)
            return CacheEntry(
                id: url.lastPathComponent,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                bytes: values?.fileSize ?? 0
            )
        }
        for id in CachePruningPolicy.evictionIDs(
            entries: entries,
            maximumCount: 40,
            maximumBytes: maxDiskBytes
        ) {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(id))
        }
    }
}
