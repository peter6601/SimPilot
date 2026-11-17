import Darwin
import Foundation

/// 聽 Unix socket，把 CLI 的請求轉給 RunnerManager。選單列 app 和 `simpilot daemon` 都用它。
public final class Daemon: @unchecked Sendable {
    public let runners: RunnerManager
    private let socketPath: String
    private var listenFD: Int32 = -1

    public init(socketPath: String = Paths.socketPath, idleSeconds: TimeInterval = 180) {
        self.socketPath = socketPath
        runners = RunnerManager(idleSeconds: idleSeconds)
    }

    /// 開始在背景 accept；socket 已被別的 daemon 佔用時丟錯。
    public func start() throws {
        listenFD = try UnixSocket.listen(socketPath)
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                DispatchQueue.global().async { self?.serve(c) }
            }
        }
    }

    /// 關掉所有 runner、移除 socket 檔
    public func shutdown() {
        runners.stop()
        if listenFD >= 0 { close(listenFD); unlink(socketPath) }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.noSigPipe(fd)
        let response: [String: Any]
        do {
            let line = try UnixSocket.readLine(fd, timeout: 10)
            let req = (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            response = handle(req)
        } catch UnixSocket.SocketError.closed {
            return  // 只是探測 daemon 在不在的連線
        } catch {
            response = ["ok": false, "error": "bad_request", "message": "\(error)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
        try? UnixSocket.writeLine(fd, data)
    }

    public func handle(_ req: [String: Any]) -> [String: Any] {
        let cmd = req["cmd"] as? String ?? ""
        let t0 = Date()
        var resp: [String: Any]
        switch cmd {
        case "ping":
            resp = ["ok": true, "pid": Int(getpid())]
        case "status":
            resp = ["ok": true, "idleSeconds": runners.idleSeconds, "runners": runners.status().map {
                ["udid": $0.udid, "port": Int($0.port), "ready": $0.ready, "requests": $0.requests,
                 "idleFor": Int(Date().timeIntervalSince($0.lastUsed))] as [String: Any]
            }]
        case "stop":
            runners.stop(udid: req["udid"] as? String)
            resp = ["ok": true]
        case "elements", "tap":
            guard let udid = req["udid"] as? String, !udid.isEmpty else {
                return ["ok": false, "error": "missing_udid"]
            }
            var query: [String: String] = [:]
            if let b = req["bundle"] as? String, !b.isEmpty {
                query["bundles"] = b
            } else {
                let candidates = Simctl.runningApps(udid: udid)
                guard !candidates.isEmpty else {
                    return ["ok": false, "error": "app_not_running", "message": "no app is running on \(udid)"]
                }
                query["bundles"] = candidates.joined(separator: ",")
            }
            if cmd == "tap" {
                guard let label = req["label"] as? String, !label.isEmpty else {
                    return ["ok": false, "error": "missing_label"]
                }
                query["label"] = label
            }
            resp = runners.get(udid: udid, path: cmd == "tap" ? "/tap" : "/elements", query: query)
        default:
            resp = ["ok": false, "error": "unknown_command", "message": cmd]
        }
        resp["seconds"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
        return resp
    }
}

public enum Simctl {
    /// 模擬器上正在跑的 app bundle id（不含 SimPilot 自己的 runner）；第三方 app 排前面。
    public static func runningApps(udid: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "spawn", udid, "launchctl", "list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseLaunchctl(String(decoding: data, as: UTF8.self))
    }

    /// 從 `launchctl list` 的輸出取出 `UIKitApplication:<bundle>[...]` 的 bundle id
    public static func parseLaunchctl(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: "UIKitApplication:") else { continue }
            let rest = line[r.upperBound...]
            let bundle = String(rest.prefix { $0 != "[" && $0 != " " && $0 != "\t" })
            if bundle.isEmpty || bundle.hasPrefix("local.simpilot.") || seen.contains(bundle) { continue }
            seen.insert(bundle)
            out.append(bundle)
        }
        return out.filter { !$0.hasPrefix("com.apple.") } + out.filter { $0.hasPrefix("com.apple.") }
    }
}
