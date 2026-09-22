import AppKit
import ApplicationServices
import Combine
import HeliarcCore
import OSLog
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let logger = Logger(subsystem: "build.robin.heliarc", category: "launch")
    private let permissions = PermissionState()
    private let settings = HeliarcSettings()
    private let updateService = UpdateService()
    private lazy var controller = HeliarcController(settings: settings)
    private var setupWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var menuBarVisibility: AnyCancellable?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        settings.refreshLaunchAtLogin()
        let loginItemFlag = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        let secondsSinceLogin = LaunchPolicy.secondsSinceLogin()
        launchedAtLogin = LaunchPolicy.isLoginItemLaunch(
            loginItemFlag: loginItemFlag,
            launchAtLogin: settings.launchAtLogin,
            secondsSinceLogin: secondsSinceLogin
        )
        logger.info("Launch: login item flag \(loginItemFlag, privacy: .public), launch at login \(self.settings.launchAtLogin, privacy: .public), login start \(self.launchedAtLogin, privacy: .public), \(Int(secondsSinceLogin), privacy: .public)s since login")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = HeliarcAssets.appIcon
        updateService.start()
        controller.permissions = permissions
        menuBarVisibility = settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in self?.setMenuBarVisible(visible) }
        if shouldShowSetupOnLaunch {
            showSetup()
        }
        controller.requestAccessibility()
        controller.start()
        if !controller.pollPermissions() {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if self?.controller.pollPermissions() == true {
                    timer.invalidate()
                    self?.permissionTimer = nil
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    /// Heliarc is a menu bar utility, so a launch at login stays in the background.
    /// The setup window opens only when the user opened the app themselves or when
    /// Heliarc cannot work without the Accessibility permission.
    private var shouldShowSetupOnLaunch: Bool {
        !launchedAtLogin || !AXIsProcessTrusted()
    }

    @objc private func showSetup() {
        settings.refreshLaunchAtLogin()
        if setupWindow == nil {
            let view = SetupView(
                permissions: permissions,
                settings: settings,
                updateService: updateService,
                requestAccessibility: { [weak self] in self?.controller.requestAccessibility() },
                retryAutomation: { [weak self] in self?.controller.checkAutomation() },
                requestScreenRecording: { [weak self] in self?.controller.requestScreenRecording() },
                resetFaviconCache: { [weak self] in self?.controller.resetFaviconCache() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Heliarc setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setMenuBarVisible(_ visible: Bool) {
        if !visible {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = HeliarcAssets.menuBarIcon
            ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Heliarc")
        let menu = NSMenu()
        menu.addItem(withTitle: "Heliarc setup…", action: #selector(showSetup), keyEquivalent: "")
        let updateItem = menu.addItem(
            withTitle: "Check for updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updateService.updaterController
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Heliarc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
