import Darwin
import Foundation

/// 給選單列顯示用的 runner 狀態快照
public struct RunnerStatus: Sendable {
    public let udid: String
    public let port: UInt16
    public let ready: Bool
    public let startedAt: Date
    public let lastUsed: Date
    public let requests: Int
}

public struct RunnerError: Error {
    public let code: String
    public let message: String
    public var json: [String: Any] { ["ok": false, "error": code, "message": message] }
}

/// 管理每台模擬器上的常駐 XCUITest server：需要時才用 xcodebuild 起來，閒置超過 idleSeconds 就關掉，
/// 讓出 xcodebuild（safe-xcodebuild.sh 只要看到有 xcodebuild 在跑就會擋掉其他 build）。
public final class RunnerManager: @unchecked Sendable {
    final class Runner {
        let udid: String
        let port: UInt16
        let process: Process
        let log: URL
        let startedAt = Date()
        var lastUsed = Date()
        var ready = false
        var requests = 0
        let queue: DispatchQueue  // 同一台模擬器的請求一次一個
        init(udid: String, port: UInt16, process: Process, log: URL) {
            self.udid = udid; self.port = port; self.process = process; self.log = log
            queue = DispatchQueue(label: "simpilot.runner.\(udid)")
        }
    }

    public var idleSeconds: TimeInterval {
        get { lock.withLock { _idle } }
        set { lock.withLock { _idle = newValue } }
    }
    public var onChange: (() -> Void)?

    private var _idle: TimeInterval
    private var runners: [String: Runner] = [:]
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let startTimeout: TimeInterval = 180

    public init(idleSeconds: TimeInterval = 180) {
        _idle = idleSeconds
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.reapIdle() }
        t.resume()
        timer = t
    }

    public func status() -> [RunnerStatus] {
        lock.withLock {
            runners.values.map {
                RunnerStatus(udid: $0.udid, port: $0.port, ready: $0.ready, startedAt: $0.startedAt,
                             lastUsed: $0.lastUsed, requests: $0.requests)
            }.sorted { $0.udid < $1.udid }
        }
    }

    // MARK: - requests

    /// 對某台模擬器的 runner 發 GET；runner 沒在跑就先起來。
    public func get(udid: String, path: String, query: [String: String]) -> [String: Any] {
        let runner: Runner
        do { runner = try ensureRunner(udid) } catch let e as RunnerError { return e.json } catch {
            return ["ok": false, "error": "runner_start_failed", "message": "\(error)"]
        }
        return runner.queue.sync {
            runner.lastUsed = Date()
            runner.requests += 1
            if !runner.ready {
                if let err = waitReady(runner) { remove(runner); return err.json }
            }
            defer { runner.lastUsed = Date(); onChange?() }
            if let r = http(runner.port, path, query, timeout: 120) { return r }
            // runner 中途掛掉（例如被 xcodebuild 以外的原因結束）：清掉，讓下一次請求重起
            remove(runner)
            return RunnerError(code: "runner_died", message: "runner stopped responding; log: \(runner.log.path)").json
        }
    }

    public func stop(udid: String? = nil) {
        let targets = lock.withLock { runners.values.filter { udid == nil || $0.udid == udid } }
        for r in targets { shutdown(r) }
    }

    // MARK: - lifecycle

    private func ensureRunner(_ udid: String) throws -> Runner {
        lock.lock()
        defer { lock.unlock() }
        if let r = runners[udid], r.process.isRunning { return r }
        guard let xctestrun = Paths.xctestrun else {
            throw RunnerError(code: "runner_not_built", message: "run `simpilot runner build` first")
        }
        let port = Self.freePort()
        let log = Paths.logsDir.appendingPathComponent("runner-\(udid).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        let (exe, prefix) = Paths.xcodebuild
        let p = Process()
        p.executableURL = exe
        p.arguments = prefix + ["test-without-building", "-xctestrun", xctestrun.path,
                                "-destination", "id=\(udid)",
                                "-only-testing:SimPilotRunner/ServerTests/testServe"]
        var env = ProcessInfo.processInfo.environment
        env["TEST_RUNNER_SERVER_PORT"] = String(port)
        // runner 自己的看門狗比 daemon 的 idle 多 60 秒：daemon 被強制結束時，runner 仍會自己收掉
        env["TEST_RUNNER_SERVER_IDLE"] = String(Int(_idle) + 60)
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        let r = Runner(udid: udid, port: port, process: p, log: log)
        runners[udid] = r
        DispatchQueue.global().async { [weak self] in self?.onChange?() }
        return r
    }

    /// 等 runner 回 /ping。xcodebuild 提早結束時，從 log 判斷原因。
    private func waitReady(_ r: Runner) -> RunnerError? {
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            if !r.process.isRunning {
                let tail = Self.tail(r.log, lines: 15)
                if tail.contains("safe-xcodebuild") {
                    // 別人的 xcodebuild 在跑：照規則不重試，把對方的 PID 和指令原樣回報
                    return RunnerError(code: "xcodebuild_busy", message: tail)
                }
                return RunnerError(code: "runner_exited",
                                   message: "xcodebuild exited (\(r.process.terminationStatus)); log: \(r.log.path)\n\(tail)")
            }
            if let pong = http(r.port, "/ping", [:], timeout: 1), pong["ok"] as? Bool == true {
                r.ready = true
                onChange?()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        r.process.terminate()
        return RunnerError(code: "runner_timeout", message: "runner not ready after \(Int(startTimeout))s; log: \(r.log.path)")
    }

    private func reapIdle() {
        let idle = idleSeconds
        let stale = lock.withLock {
            runners.values.filter { !$0.process.isRunning || ($0.ready && Date().timeIntervalSince($0.lastUsed) > idle) }
        }
        for r in stale { r.queue.async { [weak self] in self?.shutdown(r) } }
    }

    private func shutdown(_ r: Runner) {
        if r.process.isRunning {
            _ = http(r.port, "/quit", [:], timeout: 3)
            let deadline = Date().addingTimeInterval(20)
            while r.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            if r.process.isRunning { r.process.terminate() }
        }
        remove(r)
    }

    private func remove(_ r: Runner) {
        lock.withLock { if runners[r.udid] === r { runners[r.udid] = nil } }
        if r.process.isRunning { r.process.terminate() }
        onChange?()
    }

    // MARK: - helpers

    private func http(_ port: UInt16, _ path: String, _ query: [String: String], timeout: TimeInterval) -> [String: Any]? {
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = "127.0.0.1"; comps.port = Int(port); comps.path = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    /// 向系統要一個沒人用的 TCP port。模擬器跟 host 共用網路，host 上空著的 port 模擬器裡也能用。
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Int32 in
                bind(fd, p, len)
                return getsockname(fd, p, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func tail(_ url: URL, lines: Int) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
