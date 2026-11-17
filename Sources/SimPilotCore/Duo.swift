import Foundation

/// iPhone Duo 的姿態切換與 hinge 讀回。
///
/// - 切姿態：點 Device Hub 視窗上的 Closed／Partially Open／Open 按鈕（UI scripting，需要「輔助使用」權限）。
///   Device Hub 偶爾會吞掉點擊，所以切完用 `devicectl` 確認亮的是哪一面，對不上就重點，最多 3 次。
/// - 讀 hinge：沒有能從模擬器外面讀角度的公開 API。`devicectl`（公開）只告訴我們亮的是外螢幕還是內螢幕；
///   內螢幕時，book 和 open 要靠 SimPilot 上次設的姿態來分。角度一律回 null，`source` 會註明是推斷的。
public enum Duo {
    public enum Pose: String, CaseIterable, Sendable {
        case closed, book, open

        /// Device Hub 按鈕的 help 文字
        var deviceHubButton: String {
            switch self {
            case .closed: return "Closed"
            case .book: return "Partially Open"
            case .open: return "Open"
            }
        }

        /// `duo hinge` 回傳的狀態字串
        public var hingeState: String {
            switch self {
            case .closed: return "closed"
            case .book: return "partiallyOpen"
            case .open: return "openFlat"
            }
        }

        /// 這個姿態應該亮哪一面
        public var expectedDisplay: Display { self == .closed ? .outer : .inner }
    }

    public enum Display: String, Sendable { case outer, inner }

    public struct DisplayState: Sendable, Equatable {
        public let active: Display
        public let orientation: String   // devicectl 的 currentOrientation，例如 rot90
        public let name: String
    }

    public struct DuoError: Error, CustomStringConvertible {
        public let code: String
        public let message: String
        public var description: String { "\(code): \(message)" }
        public var json: [String: Any] { ["ok": false, "error": code, "message": message] }
    }

    // MARK: - display

    /// 用 `devicectl device info displays` 讀亮著的那一面。外螢幕是 primary 的那個 display。
    public static func displayState(udid: String) throws -> DisplayState {
        let out = try run("/usr/bin/xcrun", ["devicectl", "device", "info", "displays", "--device", udid, "-q", "-j", "/dev/stdout"])
        return try parseDisplays(out.stdout)
    }

    public static func parseDisplays(_ data: Data) throws -> DisplayState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else {
            throw DuoError(code: "devicectl_failed", message: "unexpected devicectl output")
        }
        guard displays.count >= 2 else {
            throw DuoError(code: "not_a_duo", message: "device has \(displays.count) display(s); iPhone Duo has two")
        }
        guard let active = displays.first(where: { $0["active"] as? Bool == true }) else {
            throw DuoError(code: "no_active_display", message: "no display is active (screen off?)")
        }
        return DisplayState(active: active["primary"] as? Bool == true ? .outer : .inner,
                            orientation: active["currentOrientation"] as? String ?? "unknown",
                            name: active["name"] as? String ?? "")
    }

    // MARK: - pose

    /// 切到指定姿態並確認。book 先切 Open 再切 Partially Open：從 Closed 直接掀到半開會一直停在外螢幕（轉軸遲滯）。
    public static func setPose(_ pose: Pose, udid: String, settle: TimeInterval = 10) throws -> [String: Any] {
        let deviceName = try simulatorName(udid: udid)
        var tries = 0
        var last: DisplayState?
        while tries < 3 {
            tries += 1
            if pose == .book {
                try clickDeviceHub("Open", deviceName: deviceName)
                _ = waitForDisplay(.inner, udid: udid, timeout: settle)
            }
            try clickDeviceHub(pose.deviceHubButton, deviceName: deviceName)
            last = waitForDisplay(pose.expectedDisplay, udid: udid, timeout: settle)
            if last?.active == pose.expectedDisplay { break }
        }
        guard let state = last, state.active == pose.expectedDisplay else {
            throw DuoError(code: "pose_not_reached",
                           message: "\(pose.rawValue): expected \(pose.expectedDisplay.rawValue) display, got \(last?.active.rawValue ?? "none") after \(tries) tries")
        }
        // 動畫結束、app 重新排版的時間
        Thread.sleep(forTimeInterval: 2)
        let final = (try? displayState(udid: udid)) ?? state
        saveLastPose(pose, udid: udid, display: final.active)
        return ["ok": true, "data": [
            "pose": pose.rawValue, "hinge_state": pose.hingeState,
            "active_display": final.active.rawValue, "display_orientation": final.orientation,
            "tries": tries, "source": "devicehub",
        ] as [String: Any]]
    }

    /// 讀回目前姿態（推斷值，見檔案開頭說明）。
    public static func hinge(udid: String) throws -> [String: Any] {
        let state = try displayState(udid: udid)
        let saved = lastPose(udid: udid)
        let hingeState: String
        let source: String
        switch state.active {
        case .outer:
            hingeState = Pose.closed.hingeState
            source = "inferred from active display (outer)"
        case .inner:
            if let saved, saved.display == .inner, saved.pose != .closed {
                hingeState = saved.pose.hingeState
                source = "inferred: inner display + last pose set by simpilot (\(saved.pose.rawValue), \(Int(Date().timeIntervalSince(saved.at)))s ago)"
            } else {
                hingeState = "unknown"
                source = "inner display is on, but book vs open cannot be told apart without a pose set by simpilot"
            }
        }
        return ["ok": true, "data": [
            "hinge_state": hingeState, "hinge_angle_degrees": NSNull(),
            "active_display": state.active.rawValue, "display_orientation": state.orientation,
            "source": source,
        ] as [String: Any]]
    }

    // MARK: - last pose

    struct SavedPose { let pose: Pose; let display: Display; let at: Date }

    static func poseFile(_ udid: String) -> URL { Paths.supportDir.appendingPathComponent("pose-\(udid).json") }

    static func saveLastPose(_ pose: Pose, udid: String, display: Display) {
        let obj: [String: Any] = ["pose": pose.rawValue, "display": display.rawValue, "at": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: poseFile(udid)) }
    }

    static func lastPose(udid: String) -> SavedPose? {
        guard let d = try? Data(contentsOf: poseFile(udid)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = (o["pose"] as? String).flatMap(Pose.init(rawValue:)),
              let disp = (o["display"] as? String).flatMap(Display.init(rawValue:)),
              let at = o["at"] as? Double else { return nil }
        return SavedPose(pose: p, display: disp, at: Date(timeIntervalSince1970: at))
    }

    // MARK: - helpers

    static func waitForDisplay(_ want: Display, udid: String, timeout: TimeInterval) -> DisplayState? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: DisplayState?
        while Date() < deadline {
            last = try? displayState(udid: udid)
            if last?.active == want { return last }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    /// Device Hub 目前顯示的裝置要是這台，避免點到別台模擬器
    static func clickDeviceHub(_ button: String, deviceName: String) throws {
        let script = """
        tell application "System Events"
          if not (exists process "DeviceHub") then return "ERR:not_running"
          tell process "DeviceHub"
            set w to window 1
            if (name of w) does not start with "\(deviceName) –" then return "ERR:wrong_device:" & (name of w)
            click (first button of group 3 of splitter group 1 of group 1 of splitter group 1 of group 1 of w whose help is "\(button)")
          end tell
        end tell
        return "OK"
        """
        let r = try run("/usr/bin/osascript", ["-e", script])
        let text = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "ERR:not_running" {
            throw DuoError(code: "devicehub_not_running", message: "open Device Hub on the \(deviceName) simulator first")
        }
        if text.hasPrefix("ERR:wrong_device:") {
            throw DuoError(code: "devicehub_wrong_device",
                           message: "Device Hub shows \"\(text.dropFirst(17))\", not \(deviceName); select it in Device Hub")
        }
        guard r.status == 0, text == "OK" else {
            let err = String(decoding: r.stderr, as: UTF8.self)
            let hint = err.contains("-1719") || err.contains("-25211") || err.contains("輔助使用") || err.contains("assistive")
                ? " (grant Accessibility permission to the app running simpilot)" : ""
            throw DuoError(code: "devicehub_click_failed", message: "\(button): \(err.trimmingCharacters(in: .whitespacesAndNewlines))\(hint)")
        }
    }

    static func simulatorName(udid: String) throws -> String {
        let r = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        guard let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else {
            throw DuoError(code: "simctl_failed", message: "cannot list simulators")
        }
        for devices in byRuntime.values {
            if let d = devices.first(where: { $0["udid"] as? String == udid }) {
                guard d["state"] as? String == "Booted" else {
                    throw DuoError(code: "not_booted", message: "\(udid) is not booted")
                }
                return d["name"] as? String ?? ""
            }
        }
        throw DuoError(code: "device_not_found", message: "no simulator with UDID \(udid)")
    }

    struct RunResult { let status: Int32; let stdout: Data; let stderr: Data }

    static func run(_ exe: String, _ args: [String]) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, stdout: o, stderr: e)
    }
}
