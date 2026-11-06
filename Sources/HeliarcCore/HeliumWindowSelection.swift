import CoreGraphics
import Foundation

/// Picks the Helium window Heliarc should read. Helium's AppleScript windows follow on-screen
/// order with no window type, so floating picture-in-picture windows come first.
public enum HeliumWindowSelection {
    /// Helium's on-screen windows, from a front-to-back `CGWindowListCopyWindowInfo` list,
    /// in CoreGraphics (top-left origin) coordinates.
    public struct ScreenWindows: Equatable {
        public var frontmostNormal: CGRect?
        public var floating: [CGRect]

        public init(frontmostNormal: CGRect?, floating: [CGRect]) {
            self.frontmostNormal = frontmostNormal
            self.floating = floating
        }
    }

    /// Frontmost normal-level window of `ownerPID` in a front-to-back window list.
    public static func frontmostNormalWindow(in windows: [[String: Any]], ownerPID: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let frame = heliumFrame(window, ownerPID: ownerPID) else { continue }
            return (CGWindowID(number.uint32Value), frame)
        }
        return nil
    }

    public static func screenWindows(in windows: [[String: Any]], ownerPID: pid_t) -> ScreenWindows {
        let floating = windows.compactMap { window -> CGRect? in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer > 0 else { return nil }
            return heliumFrame(window, ownerPID: ownerPID)
        }
        return ScreenWindows(frontmostNormal: frontmostNormalWindow(in: windows, ownerPID: ownerPID)?.bounds, floating: floating)
    }

    /// Index into Helium's AppleScript windows (front to back, bounds as {left, top, right, bottom})
    /// of the window to read: the on-screen normal window, else the frontmost window that is not
    /// floating. Returns nil when only floating windows remain.
    public static func browserWindowIndex(appleScriptBounds: [[Int]], screen: ScreenWindows) -> Int? {
        let isFloating = { (bounds: [Int]) in screen.floating.contains { matches(bounds, $0) } }
        if let target = screen.frontmostNormal,
           let index = appleScriptBounds.firstIndex(where: { matches($0, target) && !isFloating($0) }) {
            return index
        }
        return appleScriptBounds.firstIndex { !isFloating($0) }
    }

    private static func heliumFrame(_ window: [String: Any], ownerPID: pid_t) -> CGRect? {
        guard window[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 100, frame.height > 100 else { return nil }
        return frame
    }

    /// AppleScript bounds use the same top-left coordinates as CoreGraphics, rounded to points.
    private static func matches(_ bounds: [Int], _ frame: CGRect) -> Bool {
        guard bounds.count == 4 else { return false }
        let edges = [frame.minX, frame.minY, frame.maxX, frame.maxY]
        return zip(bounds, edges).allSatisfy { abs(CGFloat($0) - $1) <= 2 }
    }
}
