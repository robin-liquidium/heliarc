import XCTest
@testable import HeliarcCore

final class LaunchPolicyTests: XCTestCase {
    func testLoginItemFlagIsALoginStartEvenLongAfterBoot() {
        XCTAssertTrue(
            LaunchPolicy.isLoginItemLaunch(
                loginItemFlag: true,
                launchAtLogin: true,
                secondsSinceLogin: 9000
            )
        )
    }

    func testLaunchSecondsAfterLoginWithLaunchAtLoginIsALoginStart() {
        XCTAssertTrue(
            LaunchPolicy.isLoginItemLaunch(
                loginItemFlag: false,
                launchAtLogin: true,
                secondsSinceLogin: 45
            )
        )
    }

    func testUserLaunchLaterInTheSessionIsNotALoginStart() {
        XCTAssertFalse(
            LaunchPolicy.isLoginItemLaunch(
                loginItemFlag: false,
                launchAtLogin: true,
                secondsSinceLogin: 3600
            )
        )
    }

    func testLaunchWithoutLaunchAtLoginIsNeverALoginStart() {
        XCTAssertFalse(
            LaunchPolicy.isLoginItemLaunch(
                loginItemFlag: false,
                launchAtLogin: false,
                secondsSinceLogin: 5
            )
        )
    }

    func testSecondsSinceLoginIsPositiveAndFinite() {
        let seconds = LaunchPolicy.secondsSinceLogin()
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertLessThan(seconds, 60 * 60 * 24 * 365)
    }
}
