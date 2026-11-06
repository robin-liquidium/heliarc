import AppKit
import HeliarcCore

struct HeliumSnapshot {
    let windowID: String
    let activeTabID: String?
    let tabs: [BrowserTab]
}

struct HeliumTabIdentity: Equatable {
    let id: String
    let url: String
}

enum HeliumBridgeError: LocalizedError {
    case notRunning
    case noWindow
    case malformedReply
    case automationDenied
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Helium is not running"
        case .noWindow: return "Helium has no open window"
        case .malformedReply: return "Helium returned an unexpected reply"
        case .automationDenied: return "Allow Helium Automation access in System Settings, then retry."
        case .appleScript(let message): return message
        }
    }
}

final class HeliumBridge {
    static let bundleID = "net.imput.helium"
    private let queue = DispatchQueue(label: "build.robin.heliarc.apple-events", qos: .userInteractive)

    // Activity tracking only needs the active tab's identity and URL.
    func activeTabIdentity(completion: @escaping (Result<HeliumTabIdentity, Error>) -> Void) {
        queue.async {
            let windowID: String
            switch self.browserWindowID() {
            case .success(let id): windowID = id
            case .failure(let error): return completion(.failure(error))
            }
            let script = #"""
            tell application id "\#(Self.bundleID)"
                set browserTab to active tab of window id \#(windowID)
                return {(id of browserTab) as text, (URL of browserTab) as text}
            end tell
            """#
            completion(self.run(script).flatMap { reply in
                guard reply.numberOfItems == 2,
                      let id = reply.atIndex(1)?.stringValue,
                      let url = reply.atIndex(2)?.stringValue else {
                    return .failure(HeliumBridgeError.noWindow)
                }
                return .success(HeliumTabIdentity(id: id, url: url))
            })
        }
    }

    func snapshot(completion: @escaping (Result<HeliumSnapshot, Error>) -> Void) {
        queue.async {
            let windowID: String
            switch self.browserWindowID() {
            case .success(let id): windowID = id
            case .failure(let error): return completion(.failure(error))
            }
            let script = #"""
            tell application id "\#(Self.bundleID)"
                set browserWindow to window id \#(windowID)
                set tabRecords to properties of every tab of browserWindow
                set resultTabs to {}
                repeat with tabRecord in tabRecords
                    set end of resultTabs to {(id of tabRecord) as text, (title of tabRecord) as text, (URL of tabRecord) as text}
                end repeat
                set activeIndex to active tab index of browserWindow
                set activeID to ""
                if activeIndex > 0 and activeIndex ≤ (count of resultTabs) then
                    set activeID to item 1 of item activeIndex of resultTabs
                end if
                return {(id of browserWindow) as text, activeID, resultTabs}
            end tell
            """#
            completion(self.run(script).flatMap(self.parseSnapshot))
        }
    }

    func activate(windowID: String, tabID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Int64(windowID) != nil, Int64(tabID) != nil else {
            completion(.failure(HeliumBridgeError.malformedReply))
            return
        }
        queue.async {
            let script = #"""
            tell application id "\#(Self.bundleID)"
                repeat with browserWindow in windows
                    if (id of browserWindow) as text is "\#(windowID)" then
                        set tabRecords to properties of every tab of browserWindow
                        repeat with tabIndex from 1 to count of tabRecords
                            if (id of item tabIndex of tabRecords) as text is "\#(tabID)" then
                                set active tab index of browserWindow to tabIndex
                                return true
                            end if
                        end repeat
                    end if
                end repeat
                return false
            end tell
            """#
            completion(self.run(script).flatMap { $0.booleanValue ? .success(()) : .failure(HeliumBridgeError.malformedReply) })
        }
    }

    /// ID of the window to read, skipping floating windows such as picture-in-picture.
    private func browserWindowID() -> Result<String, Error> {
        let script = #"""
        tell application id "\#(Self.bundleID)"
            if not running then return {"NOT_RUNNING"}
            set windowList to {}
            repeat with browserWindow in windows
                set end of windowList to {(id of browserWindow) as text, bounds of browserWindow}
            end repeat
            return windowList
        end tell
        """#
        return run(script).flatMap { reply in
            if reply.numberOfItems == 1, reply.atIndex(1)?.stringValue == "NOT_RUNNING" {
                return .failure(HeliumBridgeError.notRunning)
            }
            var ids: [String] = []
            var bounds: [[Int]] = []
            for index in stride(from: 1, through: reply.numberOfItems, by: 1) {
                guard let item = reply.atIndex(index), item.numberOfItems == 2,
                      let id = item.atIndex(1)?.stringValue, Int64(id) != nil,
                      let rect = item.atIndex(2), rect.numberOfItems == 4 else { continue }
                ids.append(id)
                bounds.append((1...4).map { Int(rect.atIndex($0)?.int32Value ?? 0) })
            }
            guard let index = HeliumWindowSelection.browserWindowIndex(appleScriptBounds: bounds, screen: heliumScreenWindows()) else {
                return .failure(HeliumBridgeError.noWindow)
            }
            return .success(ids[index])
        }
    }

    private func run(_ source: String) -> Result<NSAppleEventDescriptor, Error> {
        var error: NSDictionary?
        let reply = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, error[NSAppleScript.errorNumber] as? Int == -1743 {
            return .failure(HeliumBridgeError.automationDenied)
        }
        guard let reply, error == nil else {
            let message = error?[NSAppleScript.errorMessage] as? String ?? "Helium Automation access failed"
            return .failure(HeliumBridgeError.appleScript(message))
        }
        return .success(reply)
    }

    private func parseSnapshot(_ reply: NSAppleEventDescriptor) -> Result<HeliumSnapshot, Error> {
        guard reply.numberOfItems >= 1 else { return .failure(HeliumBridgeError.malformedReply) }
        if reply.numberOfItems == 1 {
            switch reply.atIndex(1)?.stringValue {
            case "NOT_RUNNING": return .failure(HeliumBridgeError.notRunning)
            case "NO_WINDOW": return .failure(HeliumBridgeError.noWindow)
            default: break
            }
        }
        guard reply.numberOfItems == 3,
              let windowID = reply.atIndex(1)?.stringValue,
              let tabList = reply.atIndex(3) else {
            return .failure(HeliumBridgeError.malformedReply)
        }
        let activeID = reply.atIndex(2)?.stringValue
        var tabs: [BrowserTab] = []
        for index in stride(from: 1, through: tabList.numberOfItems, by: 1) {
            guard let descriptor = tabList.atIndex(index), descriptor.numberOfItems == 3,
                  let id = descriptor.atIndex(1)?.stringValue,
                  let title = descriptor.atIndex(2)?.stringValue,
                  let url = descriptor.atIndex(3)?.stringValue else { continue }
            tabs.append(BrowserTab(id: id, title: title, url: url))
        }
        return .success(HeliumSnapshot(windowID: windowID, activeTabID: activeID, tabs: tabs))
    }
}
