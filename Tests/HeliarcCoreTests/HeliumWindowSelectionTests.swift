import CoreGraphics
import XCTest
@testable import HeliarcCore

final class HeliumWindowSelectionTests: XCTestCase {
    private let heliumPID: pid_t = 42
    private let browser = CGRect(x: 0, y: 39, width: 2055, height: 1290)
    private let pip = CGRect(x: 1500, y: 900, width: 480, height: 270)

    private func window(number: Int, pid: pid_t = 42, layer: Int = 0, frame: CGRect) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary as! [String: Any],
        ]
    }

    private func appleScriptBounds(_ frame: CGRect) -> [Int] {
        [Int(frame.minX), Int(frame.minY), Int(frame.maxX), Int(frame.maxY)]
    }

    // MARK: Window list

    func testFloatingPictureInPictureWindowInFrontIsNotTheNormalWindow() {
        let windows = [window(number: 1, layer: 3, frame: pip), window(number: 2, frame: browser)]
        let selected = HeliumWindowSelection.frontmostNormalWindow(in: windows, ownerPID: heliumPID)
        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.bounds, browser)
        XCTAssertEqual(
            HeliumWindowSelection.screenWindows(in: windows, ownerPID: heliumPID),
            .init(frontmostNormal: browser, floating: [pip])
        )
    }

    func testOtherAppsAndTinyHeliumWindowsAreSkipped() {
        let windows = [
            window(number: 1, pid: 7, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
            window(number: 2, frame: CGRect(x: 1682, y: 39, width: 375, height: 60)),
            window(number: 3, frame: browser),
        ]
        XCTAssertEqual(HeliumWindowSelection.frontmostNormalWindow(in: windows, ownerPID: heliumPID)?.id, 3)
    }

    func testSmallDocumentPictureInPictureCountsAsFloating() {
        let smallPiP = CGRect(x: 1500, y: 900, width: 240, height: 86)
        let windows = [window(number: 1, layer: 3, frame: smallPiP)]
        XCTAssertEqual(HeliumWindowSelection.screenWindows(in: windows, ownerPID: heliumPID).floating, [smallPiP])
        XCTAssertNil(HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(smallPiP)],
            screen: .init(frontmostNormal: nil, floating: [smallPiP])
        ))
    }

    // MARK: Choosing the AppleScript window

    func testPicksTheOnScreenNormalWindowBehindPictureInPicture() {
        let index = HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(pip), appleScriptBounds(browser)],
            screen: .init(frontmostNormal: browser, floating: [pip])
        )
        XCTAssertEqual(index, 1)
    }

    func testPicksTheFrontmostOfSeveralNormalWindowsWithTheSameBounds() {
        let index = HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(pip), appleScriptBounds(browser), appleScriptBounds(browser)],
            screen: .init(frontmostNormal: browser, floating: [pip])
        )
        XCTAssertEqual(index, 1)
    }

    func testSkipsPictureInPictureWhenNormalWindowsAreMinimizedOrOnAnotherSpace() {
        let minimized = CGRect(x: 200, y: 200, width: 1200, height: 800)
        let index = HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(pip), appleScriptBounds(minimized)],
            screen: .init(frontmostNormal: nil, floating: [pip])
        )
        XCTAssertEqual(index, 1)
    }

    func testOnlyPictureInPictureLeftMeansNoWindow() {
        XCTAssertNil(HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(pip)],
            screen: .init(frontmostNormal: nil, floating: [pip])
        ))
    }

    func testPictureInPictureCoveringTheNormalWindowExactlyIsNotChosen() {
        let index = HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(pip), appleScriptBounds(pip)],
            screen: .init(frontmostNormal: pip, floating: [pip])
        )
        XCTAssertNil(index)
    }

    func testWithoutScreenInformationTheFrontWindowIsUsed() {
        XCTAssertEqual(HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(browser)],
            screen: .init(frontmostNormal: nil, floating: [])
        ), 0)
    }

    func testBoundsMatchAllowsRoundingButNotOtherWindows() {
        let nearby = CGRect(x: 0, y: 39.4, width: 2055, height: 1290)
        let other = CGRect(x: 10, y: 39, width: 2055, height: 1290)
        XCTAssertEqual(HeliumWindowSelection.browserWindowIndex(
            appleScriptBounds: [appleScriptBounds(other), appleScriptBounds(browser)],
            screen: .init(frontmostNormal: nearby, floating: [])
        ), 1)
    }
}
