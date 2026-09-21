import AppKit
import Carbon.HIToolbox
import HeliarcCore
import ServiceManagement
import SwiftUI

final class HeliarcSettings: ObservableObject {
    private static let storageKey = "configuration"
    static let defaultShortcut = ShortcutConfiguration(
        keyCode: Int64(kVK_Tab),
        modifiers: CGEventFlags.maskControl.rawValue
    )

    @Published var tabSwitch: ShortcutConfiguration? { didSet { save() } }
    @Published var maxRecentTabs: Int { didSet { save() } }
    @Published var showMenuBarIcon: Bool { didSet { save() } }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(HeliarcConfiguration.self, from: data) {
            tabSwitch = saved.tabSwitch
            maxRecentTabs = saved.maxRecentTabs
            showMenuBarIcon = saved.showMenuBarIcon
        } else {
            tabSwitch = Self.defaultShortcut
            maxRecentTabs = 6
            showMenuBarIcon = true
        }
        refreshLaunchAtLogin()
    }

    func reset() {
        tabSwitch = Self.defaultShortcut
        maxRecentTabs = 6
        showMenuBarIcon = true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin(preserveError: true)
    }

    func refreshLaunchAtLogin(preserveError: Bool = false) {
        if !preserveError { launchAtLoginError = nil }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private let defaults: UserDefaults

    private func save() {
        let configuration = HeliarcConfiguration(
            tabSwitch: tabSwitch,
            maxRecentTabs: maxRecentTabs,
            showMenuBarIcon: showMenuBarIcon
        )
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private func keyName(_ keyCode: Int64) -> String {
    switch Int(keyCode) {
    case kVK_Tab: return "⇥"
    case kVK_Return: return "↩"
    case kVK_Space: return "Space"
    case kVK_Delete: return "⌫"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    default: return "Key\(keyCode)"
    }
}

extension ShortcutConfiguration {
    var displayString: String {
        let flags = CGEventFlags(rawValue: modifiers)
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(keyName(keyCode))
        return parts.joined()
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut: ShortcutConfiguration? { didSet { needsDisplay = true } }
    var onRecorded: ((ShortcutConfiguration) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        record(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !record(event) { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if event.keyCode == kVK_Escape {
            recording = false
            needsDisplay = true
            window?.makeFirstResponder(nil)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        guard !modifiers.isEmpty else { return true }
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        onRecorded?(ShortcutConfiguration(keyCode: Int64(event.keyCode), modifiers: flags.rawValue))
        recording = false
        needsDisplay = true
        window?.makeFirstResponder(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let text = recording ? "Press shortcut…" : (shortcut?.displayString ?? "Unassigned")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: shortcut == nil && !recording ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: ShortcutConfiguration?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ShortcutRecorderNSView) {
        view.shortcut = shortcut
        view.onRecorded = { shortcut = $0 }
    }
}
