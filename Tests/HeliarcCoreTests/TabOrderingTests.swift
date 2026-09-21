import XCTest
@testable import HeliarcCore

final class TabOrderingTests: XCTestCase {
    private let tabs = [
        BrowserTab(id: "1", title: "One", url: "https://one.test"),
        BrowserTab(id: "2", title: "Two", url: "https://two.test"),
        BrowserTab(id: "3", title: "Three", url: "https://three.test"),
    ]

    func testActiveTabComesFirstThenMRUThenStripOrder() {
        XCTAssertEqual(
            TabOrdering.candidates(tabs: tabs, activeID: "2", mostRecentIDs: ["3", "2"]),
            [tabs[1], tabs[2], tabs[0]]
        )
    }

    func testRecordingMovesExistingTabToFrontWithoutDuplicates() {
        XCTAssertEqual(TabOrdering.recording("2", in: ["1", "2", "3"]), ["2", "1", "3"])
    }

    func testFaviconURLUsesOnlyTheWebOrigin() {
        let credentialedURL = ["https://", "user", ":", "password", "@example.com:8443/a/page?q=1#fragment"].joined()
        XCTAssertEqual(
            FaviconPolicy.faviconURL(for: credentialedURL)?.absoluteString,
            "https://example.com:8443/favicon.ico"
        )
    }

    func testFaviconURLRejectsNonWebPages() {
        XCTAssertNil(FaviconPolicy.faviconURL(for: "chrome://settings"))
        XCTAssertNil(FaviconPolicy.faviconURL(for: "file:///tmp/page.html"))
        XCTAssertNil(FaviconPolicy.faviconURL(for: "not a URL"))
    }

    func testConfigurationClampsTabCountAndPreservesDisabledShortcut() throws {
        let config = HeliarcConfiguration(tabSwitch: nil, maxRecentTabs: 99, showMenuBarIcon: false)
        XCTAssertEqual(config.maxRecentTabs, 10)
        let restored = try JSONDecoder().decode(
            HeliarcConfiguration.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertNil(restored.tabSwitch)
        XCTAssertFalse(restored.showMenuBarIcon)
    }

    func testOlderConfigurationDefaultsToShowingMenuBarIcon() throws {
        let oldJSON = #"{"tabSwitch":null,"maxRecentTabs":6}"#.data(using: .utf8)!
        let restored = try JSONDecoder().decode(HeliarcConfiguration.self, from: oldJSON)
        XCTAssertTrue(restored.showMenuBarIcon)
    }

    func testCaptureLimiterDropsConcurrentAndRecentCaptures() {
        var limiter = CaptureLimiter<String>()
        let start = Date(timeIntervalSince1970: 10)

        XCTAssertTrue(limiter.begin("one", at: start, cooldown: 3))
        XCTAssertFalse(limiter.begin("two", at: start, cooldown: 3))
        limiter.finish("one", at: start, captured: true)
        XCTAssertFalse(limiter.begin("one", at: start.addingTimeInterval(2.9), cooldown: 3))
        XCTAssertTrue(limiter.begin("one", at: start.addingTimeInterval(3), cooldown: 3))
    }

    func testFailedCaptureCanRetryImmediately() {
        var limiter = CaptureLimiter<String>()
        let start = Date(timeIntervalSince1970: 10)

        XCTAssertTrue(limiter.begin("one", at: start, cooldown: 3))
        limiter.finish("one", at: start, captured: false)
        XCTAssertTrue(limiter.begin("one", at: start, cooldown: 3))
    }

    func testCachePolicyEvictsOldestForCountAndByteLimits() {
        let entries = [
            CacheEntry(id: "old", modifiedAt: Date(timeIntervalSince1970: 1), bytes: 4),
            CacheEntry(id: "middle", modifiedAt: Date(timeIntervalSince1970: 2), bytes: 4),
            CacheEntry(id: "new", modifiedAt: Date(timeIntervalSince1970: 3), bytes: 4),
        ]
        XCTAssertEqual(
            CachePruningPolicy.evictionIDs(entries: entries, maximumCount: 2, maximumBytes: 7),
            ["old", "middle"]
        )
    }

    func testThumbnailCacheKeyChangesWhenTabNavigates() {
        let first = CacheKey.thumbnail(tabID: "7", url: "https://example.com/one")
        XCTAssertEqual(first, CacheKey.thumbnail(tabID: "7", url: "https://example.com/one"))
        XCTAssertNotEqual(first, CacheKey.thumbnail(tabID: "7", url: "https://example.com/two"))
    }
}
