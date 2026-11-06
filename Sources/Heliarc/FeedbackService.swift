import AppKit
import Foundation

enum FeedbackCategory: String, CaseIterable, Identifiable, Codable {
    case bug
    case feature
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bug: return "Bug"
        case .feature: return "Feature"
        case .other: return "Other"
        }
    }
}

/// Submits feedback to the shared robin.build relay, which files it as a public issue in
/// github.com/robin-liquidium/heliarc.
struct FeedbackService {
    /// The relay rejects larger diagnostic archives.
    static let maximumArchiveBytes = 1_500_000
    private let endpoint = URL(string: "https://dayline.robin.build/api/feedback")!

    func submit(
        category: FeedbackCategory,
        message: String,
        includeSystemInformation: Bool,
        diagnosticsArchiveURL: URL?
    ) async throws -> FeedbackIssue {
        let archive = try diagnosticsArchiveURL.map { try Data(contentsOf: $0) }
        if let archive, archive.count > Self.maximumArchiveBytes {
            throw FeedbackError.diagnosticsTooLarge
        }
        let submission = FeedbackSubmission(
            category: category,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: includeSystemInformation ? .current : nil,
            diagnosticsArchive: archive
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("macOS", forHTTPHeaderField: "X-Heliarc-Client")
        request.setValue("Heliarc", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(submission)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw FeedbackError.invalidResponse }
        if (200..<300).contains(status), let issue = try? JSONDecoder().decode(FeedbackIssue.self, from: data) {
            return issue
        }
        if let rejection = try? JSONDecoder().decode(FeedbackRejection.self, from: data) {
            throw FeedbackError.rejected(rejection.error)
        }
        throw FeedbackError.invalidResponse
    }
}

/// Build and platform details with no user or device identifiers.
struct FeedbackMetadata: Codable, Equatable {
    let appVersion: String
    let build: String
    let macOSVersion: String
    let architecture: String
    let heliumVersion: String?

    static var current: FeedbackMetadata {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #elseif arch(x86_64)
        let architecture = "Intel"
        #else
        let architecture = "Unknown"
        #endif
        return FeedbackMetadata(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            build: info?["CFBundleVersion"] as? String ?? "Unknown",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture,
            heliumVersion: installedHeliumVersion
        )
    }

    /// The relay accepts only short version strings; anything else is left out.
    static var installedHeliumVersion: String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HeliumBridge.bundleID),
              let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              version.range(of: #"^[A-Za-z0-9.+-]{1,32}$"#, options: .regularExpression) != nil else { return nil }
        return version
    }
}

private struct FeedbackSubmission: Encodable {
    let category: FeedbackCategory
    let message: String
    let metadata: FeedbackMetadata?
    let diagnosticsArchive: Data?
}

struct FeedbackIssue: Decodable, Equatable {
    let issueURL: URL
    let issueNumber: Int
}

private struct FeedbackRejection: Decodable {
    let error: String
}

enum FeedbackError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case diagnosticsTooLarge
    case diagnosticsFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Feedback could not be submitted. Please try again."
        case .rejected(let message): return message
        case .diagnosticsTooLarge: return "The diagnostics are too large to attach. Try again without them."
        case .diagnosticsFailed: return "Heliarc could not create the diagnostics archive. Try again without it."
        }
    }
}
