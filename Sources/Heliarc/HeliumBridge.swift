import AppKit
import HeliarcCore

struct HeliumSnapshot {
    let windowID: String
    let activeTabID: String?
    let tabs: [BrowserTab]
}

enum HeliumBridgeError: LocalizedError {
    case notRunning
    case noWindow
    case malformedReply
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Helium is not running"
        case .noWindow: return "Helium has no open window"
        case .malformedReply: return "Helium returned an unexpected reply"
        case .appleScript(let message): return message
        }
    }
}

final class HeliumBridge {
    static let bundleID = "net.imput.helium"
    private let queue = DispatchQueue(label: "build.robin.heliarc.apple-events", qos: .userInteractive)

    func snapshot(completion: @escaping (Result<HeliumSnapshot, Error>) -> Void) {
        queue.async {
            let script = #"""
            tell application id "net.imput.helium"
                if not running then return {"NOT_RUNNING"}
                if (count of windows) is 0 then return {"NO_WINDOW"}
                set browserWindow to front window
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
            tell application id "net.imput.helium"
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

    private func run(_ source: String) -> Result<NSAppleEventDescriptor, Error> {
        var error: NSDictionary?
        guard let reply = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
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
        for index in 1...tabList.numberOfItems {
            guard let descriptor = tabList.atIndex(index), descriptor.numberOfItems == 3,
                  let id = descriptor.atIndex(1)?.stringValue,
                  let title = descriptor.atIndex(2)?.stringValue,
                  let url = descriptor.atIndex(3)?.stringValue else { continue }
            tabs.append(BrowserTab(id: id, title: title, url: url))
        }
        return .success(HeliumSnapshot(windowID: windowID, activeTabID: activeID, tabs: tabs))
    }
}
