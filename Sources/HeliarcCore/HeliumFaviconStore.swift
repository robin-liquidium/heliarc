import Darwin
import Foundation
import SQLite3

public final class HeliumFaviconStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let heliumRoot: URL
    private let snapshotDirectory: URL
    private let refreshInterval: TimeInterval
    private var snapshotProfile: String?
    private var snapshotSourceDate: Date?
    private var refreshedAt: Date?

    public init(
        fileManager: FileManager = .default,
        heliumRoot: URL? = nil,
        snapshotDirectory: URL? = nil,
        refreshInterval: TimeInterval = 300
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.heliumRoot = heliumRoot
            ?? applicationSupport.appendingPathComponent("net.imput.helium", isDirectory: true)
        self.snapshotDirectory = snapshotDirectory
            ?? caches
                .appendingPathComponent("build.robin.heliarc", isDirectory: true)
                .appendingPathComponent("helium-favicon-db", isDirectory: true)
        self.refreshInterval = refreshInterval
    }

    public func data(for pageURL: String) -> Data? {
        guard let databaseURL = currentSnapshot() else { return nil }
        for candidate in lookupCandidates(for: pageURL) {
            if let data = query(databaseURL, pageURL: candidate) { return data }
        }
        guard let origin = originPrefix(for: pageURL) else { return nil }
        return query(databaseURL, originPrefix: origin)
    }

    public func resetSnapshot() {
        try? fileManager.removeItem(at: snapshotDirectory)
        snapshotProfile = nil
        snapshotSourceDate = nil
        refreshedAt = nil
    }

    private var snapshotURL: URL {
        snapshotDirectory.appendingPathComponent("Favicons.sqlite")
    }

    private func currentSnapshot(now: Date = Date()) -> URL? {
        guard let profile = activeProfile(), isSafeProfileName(profile) else { return existingSnapshot() }
        let source = heliumRoot.appendingPathComponent(profile, isDirectory: true).appendingPathComponent("Favicons")
        guard fileManager.fileExists(atPath: source.path) else { return existingSnapshot() }
        let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let isFresh = refreshedAt.map { now.timeIntervalSince($0) < refreshInterval } ?? false
        let sourceUnchanged = snapshotProfile == profile && snapshotSourceDate == sourceDate
        if snapshotProfile == profile, fileManager.fileExists(atPath: snapshotURL.path) {
            if isFresh { return snapshotURL }
            if sourceUnchanged {
                refreshedAt = now
                return snapshotURL
            }
        }

        if makeSnapshot(source: source) {
            snapshotProfile = profile
            snapshotSourceDate = sourceDate
            refreshedAt = now
        }
        return existingSnapshot()
    }

    private func existingSnapshot() -> URL? {
        fileManager.fileExists(atPath: snapshotURL.path) ? snapshotURL : nil
    }

    private func activeProfile() -> String? {
        let localState = heliumRoot.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let lastUsed = profile["last_used"] as? String else { return "Default" }
        return lastUsed
    }

    private func isSafeProfileName(_ value: String) -> Bool {
        value == "Default" || (value.hasPrefix("Profile ") && !value.contains("/"))
    }

    private func makeSnapshot(source: URL) -> Bool {
        try? fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        for _ in 0..<2 {
            let candidate = snapshotDirectory.appendingPathComponent("candidate-(UUID().uuidString).sqlite")
            let candidateJournal = URL(fileURLWithPath: candidate.path + "-journal")
            defer {
                try? fileManager.removeItem(at: candidate)
                try? fileManager.removeItem(at: candidateJournal)
            }
            guard cloneOrCopy(source, to: candidate) else { continue }
            let sourceJournal = URL(fileURLWithPath: source.path + "-journal")
            if fileManager.fileExists(atPath: sourceJournal.path) {
                _ = cloneOrCopy(sourceJournal, to: candidateJournal)
            }
            guard databaseIsHealthy(candidate) else { continue }
            try? fileManager.removeItem(at: snapshotURL)
            do {
                try fileManager.moveItem(at: candidate, to: snapshotURL)
                try? fileManager.removeItem(at: candidateJournal)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private func cloneOrCopy(_ source: URL, to destination: URL) -> Bool {
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        do {
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    private func databaseIsHealthy(_ url: URL) -> Bool {
        withDatabase(url, flags: SQLITE_OPEN_READWRITE) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else { return false }
            return String(cString: value) == "ok"
        } ?? false
    }

    private func query(_ url: URL, pageURL: String) -> Data? {
        query(
            url,
            sql: """
                SELECT b.image_data
                FROM icon_mapping AS m
                JOIN favicon_bitmaps AS b ON b.icon_id = m.icon_id
                WHERE m.page_url = ?1 AND length(b.image_data) > 0
                ORDER BY (b.width * b.height) DESC, b.last_updated DESC
                LIMIT 1
                """,
            binding: pageURL
        )
    }

    private func query(_ url: URL, originPrefix: String) -> Data? {
        query(
            url,
            sql: """
                SELECT b.image_data
                FROM icon_mapping AS m
                JOIN favicon_bitmaps AS b ON b.icon_id = m.icon_id
                WHERE (m.page_url = ?1 OR m.page_url LIKE ?2 ESCAPE '\\')
                  AND length(b.image_data) > 0
                ORDER BY b.last_updated DESC, (b.width * b.height) DESC
                LIMIT 1
                """,
            binding: originPrefix,
            secondBinding: escapedLikePrefix(originPrefix + "/") + "%"
        )
    }

    private func query(
        _ url: URL,
        sql: String,
        binding: String,
        secondBinding: String? = nil
    ) -> Data? {
        withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, binding, -1, SQLITE_TRANSIENT)
            if let secondBinding { sqlite3_bind_text(statement, 2, secondBinding, -1, SQLITE_TRANSIENT) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: count)
        } ?? nil
    }

    private func withDatabase<T>(
        _ url: URL,
        flags: Int32 = SQLITE_OPEN_READONLY,
        body: (OpaquePointer) -> T?
    ) -> T? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        return body(database)
    }

    private func lookupCandidates(for value: String) -> [String] {
        guard var components = URLComponents(string: value),
              components.scheme == "http" || components.scheme == "https" else { return [] }
        var result = [value]
        components.fragment = nil
        if let normalized = components.url?.absoluteString, normalized != value { result.append(normalized) }
        return result
    }

    private func originPrefix(for value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private func escapedLikePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
