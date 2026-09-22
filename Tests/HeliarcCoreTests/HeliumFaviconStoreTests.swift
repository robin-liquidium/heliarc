import Foundation
import SQLite3
import XCTest
@testable import HeliarcCore

final class HeliumFaviconStoreTests: XCTestCase {
    func testReadsExactAndOriginFallbackFromValidatedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeliumFaviconStoreTests-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profile 2", isDirectory: true)
        let snapshots = root.appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let localState = ["profile": ["last_used": "Profile 2"]]
        try JSONSerialization.data(withJSONObject: localState)
            .write(to: root.appendingPathComponent("Local State"))

        let databaseURL = profile.appendingPathComponent("Favicons")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url TEXT NOT NULL, icon_id INTEGER);
            CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER, image_data BLOB, width INTEGER, height INTEGER);
            INSERT INTO icon_mapping(page_url, icon_id) VALUES ('https://example.com/article', 7);
            INSERT INTO favicon_bitmaps(icon_id, last_updated, image_data, width, height) VALUES (7, 10, X'01020304', 32, 32);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let store = HeliumFaviconStore(
            heliumRoot: root,
            snapshotDirectory: snapshots,
            refreshInterval: 300
        )
        XCTAssertEqual(store.data(for: "https://example.com/article#section"), Data([1, 2, 3, 4]))
        XCTAssertEqual(store.data(for: "https://example.com/another-page"), Data([1, 2, 3, 4]))
    }
}
