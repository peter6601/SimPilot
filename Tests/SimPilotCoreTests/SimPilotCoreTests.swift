import XCTest
@testable import SimPilotCore

final class SimPilotCoreTests: XCTestCase {
    func testParseLaunchctlPicksThirdPartyFirstAndSkipsRunner() {
        let text = """
        PID\tStatus\tLabel
        21358\t0\tUIKitApplication:com.apple.Preferences[1a2b][rb-legacy]
        21359\t0\tUIKitApplication:com.example.demo[63cc][rb-legacy]
        21360\t0\tUIKitApplication:local.simpilot.SimPilotRunner.xctrunner[aa11][rb-legacy]
        -\t0\tcom.apple.something.else
        21361\t0\tUIKitApplication:com.example.demo[63cd][rb-legacy]
        """
        XCTAssertEqual(Simctl.parseLaunchctl(text),
                       ["com.example.demo", "com.apple.Preferences"])
    }

    func testUnixSocketRoundTripThroughDaemon() throws {
        let path = NSTemporaryDirectory() + "sp-\(UUID().uuidString.prefix(8)).sock"
        let d = Daemon(socketPath: path, idleSeconds: 60)
        try d.start()
        defer { d.shutdown() }
        let pong = try UnixSocket.request(path, ["cmd": "ping"], timeout: 5)
        XCTAssertEqual(pong["ok"] as? Bool, true)
        let missing = try UnixSocket.request(path, ["cmd": "elements"], timeout: 5)
        XCTAssertEqual(missing["error"] as? String, "missing_udid")
        let status = try UnixSocket.request(path, ["cmd": "status"], timeout: 5)
        XCTAssertEqual((status["runners"] as? [Any])?.count, 0)
    }

    func testSecondDaemonOnSameSocketIsRefused() throws {
        let path = NSTemporaryDirectory() + "sp-\(UUID().uuidString.prefix(8)).sock"
        let a = Daemon(socketPath: path)
        try a.start()
        defer { a.shutdown() }
        XCTAssertThrowsError(try Daemon(socketPath: path).start())
    }

    func testFreePortIsNonZero() {
        XCTAssertGreaterThan(RunnerManager.freePort(), 0)
    }
}

final class DuoTests: XCTestCase {
    private func displays(_ items: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["result": ["displays": items]])
    }

    func testOuterDisplayIsThePrimaryOne() throws {
        let d = displays([
            ["name": "LCD", "primary": true, "active": true, "currentOrientation": "rot0"],
            ["name": "LCD-1", "primary": false, "active": false, "currentOrientation": "rot90"],
        ])
        XCTAssertEqual(try Duo.parseDisplays(d), Duo.DisplayState(active: .outer, orientation: "rot0", name: "LCD"))
    }

    func testInnerDisplayWithRotation() throws {
        let d = displays([
            ["name": "LCD", "primary": true, "active": false, "currentOrientation": "rot0"],
            ["name": "LCD-1", "primary": false, "active": true, "currentOrientation": "rot180"],
        ])
        XCTAssertEqual(try Duo.parseDisplays(d).active, .inner)
        XCTAssertEqual(try Duo.parseDisplays(d).orientation, "rot180")
    }

    func testSingleDisplayDeviceIsRejected() {
        let d = displays([["name": "LCD", "primary": true, "active": true, "currentOrientation": "rot0"]])
        XCTAssertThrowsError(try Duo.parseDisplays(d)) { XCTAssertEqual(($0 as? Duo.DuoError)?.code, "not_a_duo") }
    }

    func testPoseMappingStrings() {
        XCTAssertEqual(Duo.Pose.closed.hingeState, "closed")
        XCTAssertEqual(Duo.Pose.book.hingeState, "partiallyOpen")
        XCTAssertEqual(Duo.Pose.open.hingeState, "openFlat")
        XCTAssertEqual(Duo.Pose.closed.expectedDisplay, .outer)
        XCTAssertEqual(Duo.Pose.book.expectedDisplay, .inner)
    }
}
