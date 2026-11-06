import Foundation
import OSLog

/// Builds the opt-in diagnostics ZIP attached to feedback. The layout must match what the
/// feedback relay accepts: `Heliarc Diagnostics/{README.txt, Logs/heliarc.log, Crash Reports/*.ips}`.
enum DiagnosticsService {
    private static let maximumLogLines = 2_000
    private static let maximumCrashReports = 3
    private static let maximumCrashReportBytes = 1_000_000

    /// Writes the archive to a temporary file the caller must delete.
    static func createArchive(summary: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let workingRoot = fileManager.temporaryDirectory
                .appendingPathComponent("heliarc-diagnostics-\(UUID().uuidString)", isDirectory: true)
            let bundleRoot = workingRoot.appendingPathComponent("Heliarc Diagnostics", isDirectory: true)
            let archiveURL = fileManager.temporaryDirectory
                .appendingPathComponent("Heliarc-Diagnostics-\(UUID().uuidString).zip")
            defer { try? fileManager.removeItem(at: workingRoot) }

            let logsRoot = bundleRoot.appendingPathComponent("Logs", isDirectory: true)
            try fileManager.createDirectory(at: logsRoot, withIntermediateDirectories: true)
            try readme(summary: summary).write(
                to: bundleRoot.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8
            )
            try recentLog().write(to: logsRoot.appendingPathComponent("heliarc.log"), atomically: true, encoding: .utf8)

            var crashReports = recentCrashReports()
            if !crashReports.isEmpty {
                let crashRoot = bundleRoot.appendingPathComponent("Crash Reports", isDirectory: true)
                try fileManager.createDirectory(at: crashRoot, withIntermediateDirectories: false)
                crashReports = crashReports.compactMap { source in
                    let destination = crashRoot.appendingPathComponent(source.lastPathComponent)
                    return (try? fileManager.copyItem(at: source, to: destination)) == nil ? nil : destination
                }
            }

            // Drop the oldest crash reports until the archive fits the relay's limit.
            do {
                return try fitArchive(bundleRoot, at: archiveURL, droppingFrom: &crashReports)
            } catch {
                try? fileManager.removeItem(at: archiveURL)
                throw error
            }
        }.value
    }

    private static func fitArchive(_ bundleRoot: URL, at archiveURL: URL, droppingFrom crashReports: inout [URL]) throws -> URL {
        let fileManager = FileManager.default
        while true {
            try? fileManager.removeItem(at: archiveURL)
            try zip(bundleRoot, to: archiveURL)
            let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            if size <= FeedbackService.maximumArchiveBytes { return archiveURL }
            guard let oldest = crashReports.popLast() else { throw FeedbackError.diagnosticsTooLarge }
            try fileManager.removeItem(at: oldest)
            if crashReports.isEmpty { try fileManager.removeItem(at: oldest.deletingLastPathComponent()) }
        }
    }

    private static func readme(summary: String) -> String {
        """
        Heliarc diagnostics
        Created: \(ISO8601DateFormatter().string(from: Date()))

        \(summary)

        This archive was uploaded because "Include diagnostics" was selected when sending feedback.
        Its public download link expires after 30 days.
        Logs/heliarc.log holds Heliarc's own log messages from the current run. Heliarc does not
        log tab titles, URLs, or browsing history. macOS crash reports may contain system and
        device identifiers, loaded-image information, and process metadata.
        """
    }

    /// Heliarc's unified-log messages since this process launched.
    private static func recentLog() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let subsystem = Bundle.main.bundleIdentifier ?? "build.robin.heliarc"
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", subsystem))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lines = entries.compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog else { return nil }
                return "\(formatter.string(from: log.date)) [\(log.category)] \(levelName(log.level)): \(log.composedMessage)"
            }
            return lines.suffix(maximumLogLines).joined(separator: "\n") + "\n"
        } catch {
            return "Could not read Heliarc's log: \(error.localizedDescription)\n"
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }

    /// Heliarc crash reports from the last 14 days, newest first.
    private static func recentCrashReports() -> [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var matches: [(url: URL, date: Date)] = []
        for root in [reports, reports.appendingPathComponent("Retired", isDirectory: true)] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
            )) ?? []
            for url in files where url.pathExtension == "ips" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let date = values.contentModificationDate, date >= cutoff,
                      let size = values.fileSize, size <= maximumCrashReportBytes,
                      isHeliarcReport(url) else { continue }
                matches.append((url, date))
            }
        }
        return matches.sorted { $0.date > $1.date }.prefix(maximumCrashReports).map(\.url)
    }

    /// `.ips` files start with a one-line JSON header naming the crashed app.
    private static func isHeliarcReport(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              let header = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] else { return false }
        return object["bundleID"] as? String == Bundle.main.bundleIdentifier
    }

    /// The relay validates ditto's exact ZIP layout, so use the same flags as Dayline.
    private static func zip(_ directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn", "--keepParent",
            directory.path, destination.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FeedbackError.diagnosticsFailed }
    }
}
