import AppKit
import HeliarcCore
import ImageIO
import OSLog

final class FaviconService: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Callback {
        let tabID: String
        let completion: (String, NSImage) -> Void
    }

    private struct Pending {
        let origin: URL
        let faviconURL: URL
        var callbacks: [Callback]
    }

    private let logger = Logger(subsystem: "build.robin.heliarc", category: "favicons")
    private let images = NSCache<NSString, NSImage>()
    private let worker: OperationQueue
    private let cacheDirectory: URL
    private let maxResponseBytes = 128 * 1_024
    private let maxDiskBytes = 2 * 1_024 * 1_024
    private let maxDiskFiles = 128
    private let maxConcurrentRequests = 2
    private var pending: [String: Pending] = [:]
    private var scheduled: [String] = []
    private var taskOrigins: [Int: String] = [:]
    private var buffers: [Int: Data] = [:]
    private var rejectedTasks = Set<Int>()
    private var failedOrigins = Set<String>()
    private var activeRequests = 0

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: worker)
    }()

    override init() {
        worker = OperationQueue()
        worker.name = "build.robin.heliarc.favicon-loader"
        worker.maxConcurrentOperationCount = 1
        worker.qualityOfService = .utility
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("build.robin.heliarc", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
        super.init()
        images.countLimit = 64
        images.totalCostLimit = 768 * 1_024
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func load(_ tabs: [BrowserTab], completion: @escaping (String, NSImage) -> Void) {
        worker.addOperation { [weak self] in
            guard let self else { return }
            for tab in tabs {
                self.load(tab, completion: completion)
            }
            self.startScheduledRequests()
        }
    }

    private func load(_ tab: BrowserTab, completion: @escaping (String, NSImage) -> Void) {
        guard let origin = FaviconPolicy.originURL(for: tab.url),
              let faviconURL = FaviconPolicy.faviconURL(for: tab.url) else { return }
        let originKey = origin.absoluteString
        let cacheKey = key(for: originKey)

        if let image = images.object(forKey: cacheKey as NSString) {
            deliver(image, tabID: tab.id, completion: completion)
            return
        }

        let diskURL = cacheDirectory.appendingPathComponent(cacheKey)
        if let data = try? Data(contentsOf: diskURL),
           let image = downsample(data) {
            images.setObject(image, forKey: cacheKey as NSString, cost: imageCost(image))
            deliver(image, tabID: tab.id, completion: completion)
            return
        }

        guard !failedOrigins.contains(originKey) else { return }
        let callback = Callback(tabID: tab.id, completion: completion)
        if pending[originKey] != nil {
            pending[originKey]?.callbacks.append(callback)
        } else {
            pending[originKey] = Pending(origin: origin, faviconURL: faviconURL, callbacks: [callback])
            scheduled.append(originKey)
        }
    }

    private func startScheduledRequests() {
        while activeRequests < maxConcurrentRequests, !scheduled.isEmpty {
            let originKey = scheduled.removeFirst()
            guard let request = pending[originKey] else { continue }
            var urlRequest = URLRequest(url: request.faviconURL)
            urlRequest.timeoutInterval = 3
            urlRequest.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: urlRequest)
            taskOrigins[task.taskIdentifier] = originKey
            buffers[task.taskIdentifier] = Data()
            activeRequests += 1
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let length = response.expectedContentLength
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              length <= Int64(maxResponseBytes) else {
            rejectedTasks.insert(dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskID = dataTask.taskIdentifier
        guard !rejectedTasks.contains(taskID),
              let existing = buffers[taskID],
              existing.count + data.count <= maxResponseBytes else {
            rejectedTasks.insert(taskID)
            buffers[taskID] = nil
            dataTask.cancel()
            return
        }
        buffers[taskID]?.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originKey = taskOrigins[task.taskIdentifier],
              let originalHost = pending[originKey]?.origin.host,
              let destination = request.url,
              destination.host?.caseInsensitiveCompare(originalHost) == .orderedSame,
              destination.scheme == "http" || destination.scheme == "https" else {
            rejectedTasks.insert(task.taskIdentifier)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        guard let originKey = taskOrigins.removeValue(forKey: taskID),
              let request = pending.removeValue(forKey: originKey) else { return }
        let data = buffers.removeValue(forKey: taskID)
        let rejected = rejectedTasks.remove(taskID) != nil
        activeRequests = max(0, activeRequests - 1)

        if error == nil, !rejected, let data, let image = downsample(data) {
            let cacheKey = key(for: originKey)
            images.setObject(image, forKey: cacheKey as NSString, cost: imageCost(image))
            store(data, at: cacheDirectory.appendingPathComponent(cacheKey))
            for callback in request.callbacks {
                deliver(image, tabID: callback.tabID, completion: callback.completion)
            }
        } else {
            failedOrigins.insert(originKey)
            logger.debug("No usable favicon for \(originKey, privacy: .private)")
        }
        startScheduledRequests()
    }

    private func deliver(_ image: NSImage, tabID: String, completion: @escaping (String, NSImage) -> Void) {
        OperationQueue.main.addOperation { completion(tabID, image) }
    }

    private func downsample(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func imageCost(_ image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 48 * 48 * 4 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }

    private func key(for origin: String) -> String {
        CacheKey.favicon(origin: origin)
    }

    private func store(_ data: Data, at url: URL) {
        try? data.write(to: url, options: .atomic)
        pruneDiskCache()
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
            maximumCount: maxDiskFiles,
            maximumBytes: maxDiskBytes
        ) {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(id))
        }
    }
}
