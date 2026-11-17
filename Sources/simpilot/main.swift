import Darwin
import Foundation
import SimPilotCore

let usage = """
simpilot — iOS 模擬器的元素讀取與點擊（輸出 JSON 到 stdout）

  simpilot elements --udid <UDID> [--bundle <id>]
  simpilot interact tap --label <文字> --udid <UDID> [--bundle <id>]
  simpilot duo pose <closed|book|open> --udid <UDID>   用 Device Hub 切姿態並確認亮的那一面
  simpilot duo hinge --udid <UDID>                     讀回姿態（推斷值：亮面＋上次設的姿態，角度為 null）
  simpilot status
  simpilot stop [--udid <UDID>]          關掉 runner，讓出 xcodebuild
  simpilot runner build                  build 模擬器裡的 XCUITest server（第一次、或改了 Runner/ 之後）
  simpilot daemon [--idle <秒>]          不開選單列 app，直接在前景當 daemon

沒指定 --bundle 時，自動挑模擬器上正在前景的 app。exit code：0 成功、1 失敗。
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func emit(_ obj: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(obj["ok"] as? Bool == true ? 0 : 1)
}

func fail(_ code: String, _ message: String) -> Never { emit(["ok": false, "error": code, "message": message]) }

func daemonIsUp(_ path: String) -> Bool {
    guard let fd = UnixSocket.connect(path) else { return false }
    close(fd)
    return true
}

/// 連 daemon；沒在跑就啟動（有選單列 app 開 app，沒有就在背景起 `simpilot daemon`）
func send(_ body: [String: Any], timeout: TimeInterval = 300) -> [String: Any] {
    let path = Paths.socketPath
    if !daemonIsUp(path) {
        let p = Process()
        if let app = Paths.appBundle {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", app.path]
        } else {
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            p.arguments = ["daemon"]
            let log = Paths.logsDir.appendingPathComponent("daemon.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try? FileHandle(forWritingTo: log)
            p.standardOutput = h
            p.standardError = h
            p.standardInput = FileHandle.nullDevice
        }
        do { try p.run() } catch { fail("daemon_start_failed", "\(error)") }
        let deadline = Date().addingTimeInterval(10)
        while !daemonIsUp(path) {
            if Date() > deadline { fail("daemon_unavailable", "no daemon on \(path)") }
            usleep(200_000)
        }
    }
    do { return try UnixSocket.request(path, body, timeout: timeout) } catch {
        fail("daemon_error", "\(error)")
    }
}

func runnerBuild() -> Never {
    let dir = Paths.runnerProjectDir
    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    gen.arguments = ["xcodegen", "generate", "--quiet"]
    gen.currentDirectoryURL = dir
    do { try gen.run(); gen.waitUntilExit() } catch { fail("xcodegen_failed", "\(error)") }
    guard gen.terminationStatus == 0 else { fail("xcodegen_failed", "exit \(gen.terminationStatus)") }

    let (exe, prefix) = Paths.xcodebuild
    let p = Process()
    p.executableURL = exe
    p.arguments = prefix + ["build-for-testing", "-project", dir.appendingPathComponent("SimPilotRunner.xcodeproj").path,
                            "-scheme", "SimPilotRunner", "-destination", "generic/platform=iOS Simulator",
                            "-derivedDataPath", Paths.runnerDerivedData.path, "-quiet"]
    do { try p.run(); p.waitUntilExit() } catch { fail("build_failed", "\(error)") }
    if p.terminationStatus != 0 {
        fail(p.terminationStatus == 1 ? "xcodebuild_busy_or_failed" : "build_failed",
             "xcodebuild exit \(p.terminationStatus)（exit 1 也可能是 safe-xcodebuild 擋下：見上方 stderr）")
    }
    emit(["ok": true, "xctestrun": Paths.xctestrun?.path ?? ""])
}

func runDaemon() -> Never {
    let idle = TimeInterval(option("--idle") ?? "") ?? 180
    let d = Daemon(idleSeconds: idle)
    do { try d.start() } catch { fail("daemon_start_failed", "\(error)") }
    FileHandle.standardError.write(Data("simpilot daemon listening on \(Paths.socketPath), idle \(Int(idle))s\n".utf8))
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { d.shutdown(); exit(0) }
        s.resume()
        sources.append(s)
    }
    dispatchMain()
}

switch args.first {
case "elements":
    guard let udid = option("--udid") else { fail("missing_udid", "--udid is required") }
    emit(send(["cmd": "elements", "udid": udid, "bundle": option("--bundle") ?? ""]))
case "interact":
    guard args.dropFirst().first == "tap" else { fail("unsupported", "only `interact tap` is implemented") }
    guard let udid = option("--udid") else { fail("missing_udid", "--udid is required") }
    guard let label = option("--label") else { fail("missing_label", "--label is required") }
    // 不認得的參數（例如 --screen latest）接受但忽略
    emit(send(["cmd": "tap", "udid": udid, "label": label, "bundle": option("--bundle") ?? ""]))
case "duo":
    // 不經 daemon：點 Device Hub 要用跑 CLI 的這個 app 的「輔助使用」權限
    guard let udid = option("--udid") else { fail("missing_udid", "--udid is required") }
    do {
        switch args.dropFirst().first {
        case "pose":
            guard let name = args.dropFirst(2).first, let pose = Duo.Pose(rawValue: name) else {
                fail("bad_pose", "usage: simpilot duo pose closed|book|open --udid <UDID>")
            }
            emit(try Duo.setPose(pose, udid: udid))
        case "hinge":
            emit(try Duo.hinge(udid: udid))
        default:
            fail("unsupported", "usage: simpilot duo pose|hinge ...")
        }
    } catch let e as Duo.DuoError {
        emit(e.json)
    } catch {
        fail("duo_failed", "\(error)")
    }
case "status":
    emit(send(["cmd": "status"], timeout: 10))
case "stop":
    var body: [String: Any] = ["cmd": "stop"]
    if let udid = option("--udid") { body["udid"] = udid }
    emit(send(body, timeout: 60))
case "runner":
    guard args.dropFirst().first == "build" else { fail("unsupported", "usage: simpilot runner build") }
    runnerBuild()
case "daemon":
    runDaemon()
default:
    print(usage)
    exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 2)
}
