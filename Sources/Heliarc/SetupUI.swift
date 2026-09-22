import AppKit
import SwiftUI

final class PermissionState: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var automationMessage = "Checking Helium…"
    @Published var automationReady = false
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
}

struct SetupView: View {
    @ObservedObject var permissions: PermissionState
    @ObservedObject var settings: HeliarcSettings
    @ObservedObject var updateService: UpdateService
    let requestAccessibility: () -> Void
    let retryAutomation: () -> Void
    let requestScreenRecording: () -> Void
    let resetFaviconCache: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if let logo = HeliarcAssets.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "rectangle.3.group.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heliarc").font(.title2.bold())
                    Text("A native Ctrl-Tab switcher for Helium")
                        .foregroundStyle(.secondary)
                }
            }

            permissionRow(
                title: "Accessibility",
                detail: permissions.accessibility ? "Ready" : "Required for the global Ctrl-Tab shortcut",
                ready: permissions.accessibility,
                button: permissions.accessibility ? nil : ("Allow", requestAccessibility)
            )
            permissionRow(
                title: "Screen Recording",
                detail: permissions.screenRecording ? "Ready — low-resolution thumbnail snapshots enabled" : "Optional — enables cached tab thumbnails",
                ready: permissions.screenRecording,
                button: permissions.screenRecording ? nil : ("Allow", requestScreenRecording)
            )
            permissionRow(
                title: "Helium Automation",
                detail: permissions.automationMessage,
                ready: permissions.automationReady,
                button: permissions.automationReady ? nil : ("Retry", retryAutomation)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Switcher settings")
                    .font(.headline)

                HStack {
                    Text("Switch tabs")
                    Spacer()
                    ShortcutRecorderView(shortcut: $settings.tabSwitch)
                        .frame(width: 130, height: 30)
                    Button {
                        settings.tabSwitch = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Disable shortcut")
                }

                HStack {
                    Text("Maximum recent tabs")
                    Spacer()
                    Picker("Maximum recent tabs", selection: $settings.maxRecentTabs) {
                        ForEach(2...10, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }

                Toggle("Show Heliarc in menu bar", isOn: $settings.showMenuBarIcon)

                if !settings.showMenuBarIcon {
                    Text("Heliarc keeps running. Open it again from Applications to return to this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Launch Heliarc at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )

                if settings.launchAtLoginNeedsApproval {
                    HStack {
                        Text("macOS needs your approval before Heliarc can launch at login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { settings.openLoginItemsSettings() }
                            .font(.caption)
                    }
                } else if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updateService.automaticallyChecksForUpdates },
                        set: { updateService.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { updateService.automaticallyDownloadsUpdates },
                        set: { updateService.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updateService.automaticallyChecksForUpdates)

                Button("Check for updates…") { updateService.checkForUpdates() }
                    .disabled(!updateService.canCheckForUpdates)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Heliarc keeps up to 512 favicons locally. Resetting does not change Helium's browser data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reset favicon cache", action: resetFaviconCache)
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                Button("Reset to defaults") { settings.reset() }
                    .font(.caption)
                    .buttonStyle(.link)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Divider()
            HStack {
                Text(settings.tabSwitch.map { "Use \($0.displayString) and add Shift to reverse while Helium is frontmost." } ?? "The global tab-switch shortcut is disabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        ready: Bool,
        button: (String, () -> Void)?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .font(.system(size: 19))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let button { Button(button.0, action: button.1) }
        }
    }
}
