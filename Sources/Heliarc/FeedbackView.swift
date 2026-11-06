import SwiftUI

/// Submission state that outlives the view, so the window can refuse to close mid-send.
final class FeedbackSession: ObservableObject {
    @Published var isSubmitting = false
}

/// Sends feedback as a public GitHub issue, optionally with system information and diagnostics.
struct FeedbackView: View {
    @ObservedObject var session: FeedbackSession
    @ObservedObject var permissions: PermissionState
    @ObservedObject var settings: HeliarcSettings
    let close: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var category = FeedbackCategory.bug
    @State private var message = ""
    @State private var includesSystemInformation = true
    @State private var includesDiagnostics = false
    @State private var errorMessage: String?
    @State private var submittedIssue: FeedbackIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send feedback").font(.title2.bold())
            if let submittedIssue {
                submitted(submittedIssue)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var form: some View {
        Group {
            Picker("Type", selection: $category) {
                ForEach(FeedbackCategory.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(category == .bug ? "What happened, and what did you expect?" : "What would you like to tell us?")
                .font(.headline)

            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .frame(height: 160)
                .accessibilityLabel("Feedback message")

            option(
                "Include app and system information",
                isOn: $includesSystemInformation,
                detail: "Heliarc, Helium and macOS versions, and chip type."
            )
            option(
                "Include diagnostics",
                isOn: $includesDiagnostics,
                detail: "Uploads a ZIP with Heliarc's log from this run, permission and settings status, and up to three recent Heliarc crash reports. The public issue links to it for 30 days. It has no tab titles, URLs, or browsing history, but macOS crash reports can contain device identifiers and system details."
            )

            Label(
                "Your feedback is posted publicly in the Heliarc GitHub repository. Don't include personal information.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isSubmitting)
                Button(session.isSubmitting ? "Sending…" : "Send") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .disabled(session.isSubmitting)
    }

    private func option(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private func submitted(_ issue: FeedbackIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Thanks! Your feedback is issue #\(issue.issueNumber).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("The issue is public, so you can follow it on GitHub without signing in.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("View on GitHub") { openURL(issue.issueURL) }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canSubmit: Bool {
        !session.isSubmitting && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        session.isSubmitting = true
        errorMessage = nil
        defer { session.isSubmitting = false }
        do {
            let archive = includesDiagnostics ? try await DiagnosticsService.createArchive(summary: diagnosticsSummary) : nil
            defer { if let archive { try? FileManager.default.removeItem(at: archive) } }
            submittedIssue = try await FeedbackService().submit(
                category: category,
                message: message,
                includeSystemInformation: includesSystemInformation,
                diagnosticsArchiveURL: archive
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var diagnosticsSummary: String {
        let metadata = FeedbackMetadata.current
        return """
        Heliarc: \(metadata.appVersion) (build \(metadata.build))
        Helium: \(metadata.heliumVersion ?? "not found")
        macOS: \(metadata.macOSVersion) (\(metadata.architecture))

        Accessibility: \(permissions.accessibility ? "allowed" : "not allowed")
        Screen Recording: \(permissions.screenRecording ? "allowed" : "not allowed")
        Helium Automation: \(permissions.automationMessage)

        Switch tabs shortcut: \(settings.tabSwitch?.displayString ?? "disabled")
        Maximum recent tabs: \(settings.maxRecentTabs)
        Menu bar icon: \(settings.showMenuBarIcon ? "shown" : "hidden")
        Launch at login: \(settings.launchAtLogin ? "on" : "off")
        """
    }
}
