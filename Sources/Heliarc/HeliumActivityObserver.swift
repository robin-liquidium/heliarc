import AppKit
import ApplicationServices

final class HeliumActivityObserver {
    static let heliumBundleID = "net.imput.helium"

    private final class CallbackContext {
        weak var owner: HeliumActivityObserver?
        var isActive = true

        init(owner: HeliumActivityObserver) {
            self.owner = owner
        }

        func notify() {
            guard isActive else { return }
            owner?.handleAccessibilityChange()
        }
    }

    private let workspace: NSWorkspace
    private let onChange: () -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var accessibilityObserver: AXObserver?
    private var accessibilityApplication: AXUIElement?
    private var accessibilityPID: pid_t?
    private var callbackContext: CallbackContext?
    private var fallbackTimer: Timer?
    private var started = false

    init(workspace: NSWorkspace = .shared, onChange: @escaping () -> Void) {
        self.workspace = workspace
        self.onChange = onChange
    }

    deinit {
        fallbackTimer?.invalidate()
        workspaceObservers.forEach(workspace.notificationCenter.removeObserver)
        callbackContext?.isActive = false
        if let observer = accessibilityObserver, let application = accessibilityApplication {
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedUIElementChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedWindowChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
    }

    func start() {
        guard !started else { return }
        started = true
        observeWorkspaceLifecycle()
        refresh()
        onChange()
    }

    func refresh() {
        guard started else { return }
        reattachAccessibilityObserverIfNeeded()
        updateFallbackTimer()
    }

    private func observeWorkspaceLifecycle() {
        let center = workspace.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ]

        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      application.bundleIdentifier == Self.heliumBundleID else { return }
                self?.handleLifecycleNotification(name, application: application)
            }
        }
    }

    private func handleLifecycleNotification(
        _ name: Notification.Name,
        application: NSRunningApplication
    ) {
        if name == NSWorkspace.didTerminateApplicationNotification {
            if accessibilityPID == application.processIdentifier {
                removeAccessibilityObserver()
            }
            updateFallbackTimer()
            return
        }

        reattachAccessibilityObserverIfNeeded(preferredApplication: application)
        updateFallbackTimer()
        if name == NSWorkspace.didActivateApplicationNotification {
            onChange()
        }
    }

    private func reattachAccessibilityObserverIfNeeded(
        preferredApplication: NSRunningApplication? = nil
    ) {
        guard AXIsProcessTrusted(),
              let application = runningHelium(preferredApplication: preferredApplication) else {
            removeAccessibilityObserver()
            return
        }

        let pid = application.processIdentifier
        guard pid != accessibilityPID || accessibilityObserver == nil else { return }
        removeAccessibilityObserver()

        var observer: AXObserver?
        let createResult = AXObserverCreate(pid, Self.accessibilityCallback, &observer)
        guard createResult == .success, let observer else { return }

        let applicationElement = AXUIElementCreateApplication(pid)
        let context = CallbackContext(owner: self)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
        ]

        var registeredNotifications: [CFString] = []
        for notification in notifications {
            let result = AXObserverAddNotification(observer, applicationElement, notification, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }

        guard !registeredNotifications.isEmpty else {
            context.isActive = false
            return
        }

        accessibilityObserver = observer
        accessibilityApplication = applicationElement
        accessibilityPID = pid
        callbackContext = context
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeAccessibilityObserver() {
        callbackContext?.isActive = false
        if let observer = accessibilityObserver, let application = accessibilityApplication {
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedUIElementChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedWindowChangedNotification as CFString
            )
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        accessibilityObserver = nil
        accessibilityApplication = nil
        accessibilityPID = nil
        callbackContext = nil
    }

    private func updateFallbackTimer() {
        guard isHeliumForeground else {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            return
        }
        guard fallbackTimer == nil else { return }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isHeliumForeground else { return }
            self.onChange()
        }
    }

    private func handleAccessibilityChange() {
        guard isHeliumForeground else { return }
        onChange()
    }

    private func runningHelium(
        preferredApplication: NSRunningApplication? = nil
    ) -> NSRunningApplication? {
        if let preferredApplication,
           preferredApplication.bundleIdentifier == Self.heliumBundleID,
           !preferredApplication.isTerminated {
            return preferredApplication
        }
        return workspace.runningApplications.first {
            $0.bundleIdentifier == Self.heliumBundleID && !$0.isTerminated
        }
    }

    private var isHeliumForeground: Bool {
        workspace.frontmostApplication?.bundleIdentifier == Self.heliumBundleID
    }

    private static let accessibilityCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue().notify()
    }
}
