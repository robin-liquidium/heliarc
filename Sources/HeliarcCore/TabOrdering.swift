import Foundation

public struct BrowserTab: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public enum TabOrdering {
    public static func candidates(
        tabs: [BrowserTab],
        activeID: String?,
        mostRecentIDs: [String],
        limit: Int = 6
    ) -> [BrowserTab] {
        guard limit > 0 else { return [] }
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [BrowserTab] = []

        func append(_ id: String?) {
            guard let id, !seen.contains(id), let tab = tabsByID[id] else { return }
            seen.insert(id)
            result.append(tab)
        }

        append(activeID)
        for id in mostRecentIDs { append(id) }
        for tab in tabs { append(tab.id) }
        return Array(result.prefix(limit))
    }

    public static func recording(_ id: String, in ids: [String], limit: Int = 100) -> [String] {
        guard limit > 0 else { return [] }
        return Array(([id] + ids.filter { $0 != id }).prefix(limit))
    }
}

public enum FaviconPolicy {
    public static func originURL(for pageURL: String) -> URL? {
        guard var components = URLComponents(string: pageURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func faviconURL(for pageURL: String) -> URL? {
        originURL(for: pageURL)?.appendingPathComponent("favicon.ico")
    }
}
