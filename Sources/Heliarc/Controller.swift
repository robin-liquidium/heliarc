import AppKit
import ApplicationServices
import HeliarcCore
import OSLog

final class HeliarcController {
    private let logger = Logger(subsystem: "build.robin.heliarc", category: "runtime")
    private let bridge = HeliumBridge()
    private lazy var activityObserver = HeliumActivityObserver { [weak self] in
        self?.refreshActiveTab()
    }
    private var activityReadInFlight = false
    private var activityReadPending = false
    private var activityGeneration = 0
    private var activationInProgress = false
    private var activityReadsAllowed = true
    private let thumbnails = ThumbnailService()
    private let favicons = FaviconService()
    private let state = SwitcherState()
    private lazy var panel = SwitcherPanel(state: state)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var candidates: [BrowserTab] = []
    private var windowID = ""
    private var pendingSteps = 0
    private var loading = false
    private var sessionActive = false
    private var commitPending = false
    private var sourceCaptureInProgress = false
    private var thumbnailCaptureGeneration = 0
    private var mru: [String] = []
    private var lastAccessibilityState: Bool?
    private let settings: HeliarcSettings
    var permissions: PermissionState?

    init(settings: HeliarcSettings) {
        self.settings = settings
        state.onHover = { [weak self] index in self?.select(index) }
    }

    func start() {
        logger.info("Heliarc started")
        installEventTapIfAllowed()
        checkAutomation()
        activityObserver.start()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func pollPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        permissions?.accessibility = trusted
        permissions?.screenRecording = thumbnails.hasPermission
        if lastAccessibilityState != trusted {
            logger.info("Accessibility trusted: \(trusted, privacy: .public)")
            lastAccessibilityState = trusted
        }
        installEventTapIfAllowed()
        activityObserver.refresh()
        return trusted
    }

    func requestScreenRecording() {
        permissions?.screenRecording = thumbnails.requestPermission()
    }

    func checkAutomation() {
        bridge.snapshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.activityReadsAllowed = true
                    self.logger.info("Helium Automation ready; tabs: \(snapshot.tabs.count, privacy: .public)")
                    self.permissions?.automationReady = true
                    self.permissions?.automationMessage = "Ready — \(snapshot.tabs.count) tabs found"
                    self.refreshActiveTab()
                case .failure(let error):
                    if case HeliumBridgeError.automationDenied = error { self.activityReadsAllowed = false }
                    self.logger.error("Helium Automation failed: \(error.localizedDescription, privacy: .public)")
                    self.permissions?.automationReady = false
                    self.permissions?.automationMessage = error.localizedDescription
                }
            }
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifierMask = CGEventFlags([.maskControl, .maskShift, .maskCommand, .maskAlternate]).rawValue
        let currentModifiers = event.flags.rawValue & modifierMask
        let shortcut = settings.tabSwitch
        let baseModifiers = (shortcut?.modifiers ?? 0) & ~CGEventFlags.maskShift.rawValue
        let currentBaseModifiers = currentModifiers & ~CGEventFlags.maskShift.rawValue
        if type == .keyDown, let shortcut,
           keyCode == shortcut.keyCode,
           currentBaseModifiers == baseModifiers,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == HeliumBridge.bundleID {
            cycle(backward: currentModifiers & CGEventFlags.maskShift.rawValue != 0)
            return true
        }
        if type == .keyDown, keyCode == 53, sessionActive {
            cancel()
            return true
        }
        if type == .flagsChanged, sessionActive,
           baseModifiers == 0 || currentModifiers & baseModifiers != baseModifiers {
            commit()
        }
        return false
    }

    private func cycle(backward: Bool) {
        let step = backward ? -1 : 1
        if sessionActive, !loading, !candidates.isEmpty {
            let next = (state.selectedIndex + step + candidates.count) % candidates.count
            select(next)
            return
        }
        thumbnailCaptureGeneration &+= 1
        pendingSteps += step
        guard !loading else { return }
        activityGeneration &+= 1
        loading = true
        sessionActive = true
        bridge.snapshot { [weak self] result in
            DispatchQueue.main.async { self?.loaded(result) }
        }
    }

    private func loaded(_ result: Result<HeliumSnapshot, Error>) {
        loading = false
        switch result {
        case .failure(let error):
            cancel()
            permissions?.automationReady = false
            permissions?.automationMessage = error.localizedDescription
        case .success(let snapshot):
            activityReadsAllowed = true
            permissions?.automationReady = true
            permissions?.automationMessage = "Ready — \(snapshot.tabs.count) tabs found"
            if let active = snapshot.activeTabID { record(active) }
            candidates = TabOrdering.candidates(
                tabs: snapshot.tabs,
                activeID: snapshot.activeTabID,
                mostRecentIDs: mru,
                limit: settings.maxRecentTabs
            )
            windowID = snapshot.windowID
            guard !candidates.isEmpty else { cancel(); return }
            let count = candidates.count
            let normalized = ((pendingSteps % count) + count) % count
            pendingSteps = 0
            state.show(tabs: candidates, selectedIndex: normalized)
            panel.present(over: frontmostHeliumWindowFrame(), tabCount: count)
            thumbnails.load(candidates) { [weak self] images in
                guard let self, self.sessionActive else { return }
                self.state.setThumbnails(images)
            }
            favicons.load(candidates) { [weak self] tabID, image in
                guard let self, self.sessionActive,
                      self.candidates.contains(where: { $0.id == tabID }) else { return }
                self.state.setFavicon(image, for: tabID)
            }
            if let activeID = snapshot.activeTabID,
               let activeTab = snapshot.tabs.first(where: { $0.id == activeID }) {
                captureSourceThumbnail(activeTab)
            }
            if commitPending, !sourceCaptureInProgress { commit() }
        }
    }

    private func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        state.selectedIndex = index
    }

    private func commit() {
        guard sessionActive else { return }
        if loading || sourceCaptureInProgress {
            commitPending = true
            return
        }
        commitPending = false
        guard candidates.indices.contains(state.selectedIndex) else { cancel(); return }
        let tab = candidates[state.selectedIndex]
        let targetWindow = windowID
        hideSession()
        activityGeneration &+= 1
        activationInProgress = true
        bridge.activate(windowID: targetWindow, tabID: tab.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activationInProgress = false
                if case .success = result { self.record(tab.id) }
                self.refreshActiveTab()
            }
        }
    }

    private func cancel() {
        thumbnailCaptureGeneration &+= 1
        hideSession()
        refreshActiveTab()
    }

    private func hideSession() {
        sessionActive = false
        loading = false
        commitPending = false
        sourceCaptureInProgress = false
        pendingSteps = 0
        candidates = []
        panel.orderOut(nil)
        state.hide()
    }

    private func record(_ id: String) {
        guard mru.first != id else { return }
        mru = TabOrdering.recording(id, in: mru)
    }

    private func refreshActiveTab() {
        guard !sessionActive, !activationInProgress,
              activityReadsAllowed,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == HeliumBridge.bundleID else { return }
        if activityReadInFlight {
            activityReadPending = true
            return
        }
        activityReadInFlight = true
        activityReadPending = false
        let generation = activityGeneration
        let pid = app.processIdentifier
        bridge.activeTabID { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activityReadInFlight = false
                if case .failure(HeliumBridgeError.automationDenied) = result {
                    self.activityReadsAllowed = false
                }
                // A delayed observation must not undo a newer switcher selection.
                if self.activityGeneration == generation,
                   !self.sessionActive, !self.activationInProgress,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                   case .success(let id) = result {
                    self.record(id)
                }
                if self.activityReadPending {
                    self.activityReadPending = false
                    self.refreshActiveTab()
                }
            }
        }
    }

    private func captureSourceThumbnail(_ tab: BrowserTab) {
        let generation = thumbnailCaptureGeneration
        sourceCaptureInProgress = true
        thumbnails.capture(tab, isCurrent: { [weak self] in
            guard let self else { return false }
            return self.sessionActive && self.thumbnailCaptureGeneration == generation
        }) { [weak self] image in
            guard let self, self.thumbnailCaptureGeneration == generation else { return }
            self.sourceCaptureInProgress = false
            if let image, self.sessionActive {
                self.state.setThumbnail(image, for: tab.id)
            }
            if self.commitPending { self.commit() }
        }
    }

    private func installEventTapIfAllowed() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<HeliarcController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Global shortcut event tap installed")
    }
}
