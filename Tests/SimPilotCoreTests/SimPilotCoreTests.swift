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
