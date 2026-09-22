import Foundation
import CryptoKit

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var keyCode: Int64
    public var modifiers: UInt64

    public init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HeliarcConfiguration: Codable, Equatable, Sendable {
    public var tabSwitch: ShortcutConfiguration?
    public var maxRecentTabs: Int
    public var showMenuBarIcon: Bool

    public init(
        tabSwitch: ShortcutConfiguration?,
        maxRecentTabs: Int = 6,
        showMenuBarIcon: Bool = true
    ) {
        self.tabSwitch = tabSwitch
        self.maxRecentTabs = min(10, max(2, maxRecentTabs))
        self.showMenuBarIcon = showMenuBarIcon
    }

    private enum CodingKeys: String, CodingKey {
        case tabSwitch
        case maxRecentTabs
        case showMenuBarIcon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabSwitch = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .tabSwitch)
        maxRecentTabs = min(10, max(2, try container.decodeIfPresent(Int.self, forKey: .maxRecentTabs) ?? 6))
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
    }
}

public struct CaptureLimiter<Key: Hashable> {
    private var activeKey: Key?
    private var capturedAt: [Key: Date] = [:]

    public init() {}

    public mutating func begin(_ key: Key, at now: Date, cooldown: TimeInterval) -> Bool {
        capturedAt = capturedAt.filter { now.timeIntervalSince($0.value) < cooldown }
        guard activeKey == nil,
              capturedAt[key].map({ now.timeIntervalSince($0) >= cooldown }) ?? true else {
            return false
        }
        activeKey = key
        return true
    }

    public mutating func finish(_ key: Key, at now: Date, captured: Bool) {
        guard activeKey == key else { return }
        activeKey = nil
        if captured { capturedAt[key] = now }
    }
}

public enum LaunchPolicy {
    /// A start this soon after the user logs in is macOS launching Heliarc as a
    /// login item, which is not a user request, so the setup window stays closed.
    public static let loginLaunchWindow: TimeInterval = 180

    public static func isLoginItemLaunch(
        loginItemFlag: Bool,
        launchAtLogin: Bool,
        secondsSinceLogin: TimeInterval
    ) -> Bool {
        if loginItemFlag { return true }
        return launchAtLogin && secondsSinceLogin < loginLaunchWindow
    }

    /// Wall-clock time since the console user logged in, falling back to boot time,
    /// so that time spent asleep or at the login window still counts.
    public static func secondsSinceLogin(now: Date = Date()) -> TimeInterval {
        let reference = max(bootDate() ?? .distantPast, consoleLoginDate() ?? .distantPast)
        guard reference > .distantPast else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(reference)
    }

    private static func bootDate() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
    }

    private static func consoleLoginDate() -> Date? {
        var latest: Date?
        setutxent()
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS,
                  fixedString(entry.pointee.ut_line) == "console" else { continue }
            latest = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
        }
        endutxent()
        return latest
    }

    private static func fixedString<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

public struct CacheEntry: Equatable, Sendable {
    public let id: String
    public let modifiedAt: Date
    public let bytes: Int

    public init(id: String, modifiedAt: Date, bytes: Int) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.bytes = max(0, bytes)
    }
}

public enum CachePruningPolicy {
    public static func evictionIDs(
        entries: [CacheEntry],
        maximumCount: Int,
        maximumBytes: Int
    ) -> [String] {
        var remaining = entries.sorted { $0.modifiedAt < $1.modifiedAt }
        var totalBytes = remaining.reduce(0) { $0 + $1.bytes }
        var evictions: [String] = []
        while remaining.count > max(0, maximumCount) || totalBytes > max(0, maximumBytes) {
            guard !remaining.isEmpty else { break }
            let oldest = remaining.removeFirst()
            totalBytes -= oldest.bytes
            evictions.append(oldest.id)
        }
        return evictions
    }
}

public enum CacheKey {
    public static func thumbnail(tabID: String, url: String) -> String {
        digest("\(tabID)|\(url)", prefixBytes: 12)
    }

    public static func favicon(origin: String) -> String {
        digest(origin, prefixBytes: nil)
    }

    private static func digest(_ value: String, prefixBytes: Int?) -> String {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)))
        let selected = bytes.prefix(prefixBytes ?? bytes.count)
        return selected.map { String(format: "%02x", $0) }.joined()
    }
}
