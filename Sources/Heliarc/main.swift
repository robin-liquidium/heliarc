import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let permissions = PermissionState()
    private let settings = HeliarcSettings()
    private lazy var controller = HeliarcController(settings: settings)
    private var setupWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var menuBarVisibility: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = HeliarcAssets.appIcon
        controller.permissions = permissions
        menuBarVisibility = settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in self?.setMenuBarVisible(visible) }
        showSetup()
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

    @objc private func showSetup() {
        settings.refreshLaunchAtLogin()
        if setupWindow == nil {
            let view = SetupView(
                permissions: permissions,
                settings: settings,
                requestAccessibility: { [weak self] in self?.controller.requestAccessibility() },
                retryAutomation: { [weak self] in self?.controller.checkAutomation() },
                requestScreenRecording: { [weak self] in self?.controller.requestScreenRecording() }
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
