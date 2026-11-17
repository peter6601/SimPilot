import Network
import XCTest

/// 常駐在模擬器裡的 XCUITest HTTP server。由 SimPilot daemon 用 xcodebuild test-without-building 啟動，
/// 只附掛已在跑的 app，從不呼叫 launch()／activate()（launch() 會把 app 終止重開）。
///
///   GET /ping
///   GET /elements?bundles=a,b      bundles：候選 bundle id，取第一個在前景的
///   GET /tap?label=文字&bundles=a,b
///   GET /quit
///
/// 環境變數（xcodebuild 端加 TEST_RUNNER_ 前綴）：
///   SERVER_PORT  監聽的 port（模擬器跟 host 共用網路）
///   SERVER_IDLE  幾秒沒收到請求就自己結束；daemon 掛掉時避免 xcodebuild 一直佔著
final class ServerTests: XCTestCase {
    private var cache: [String: XCUIApplication] = [:]
    private var lastRequest = Date()

    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let port = NWEndpoint.Port(rawValue: UInt16(env["SERVER_PORT"] ?? "") ?? 18765)!
        let idle = TimeInterval(env["SERVER_IDLE"] ?? "") ?? 600
        let listener = try NWListener(using: .tcp, on: port)
        let done = expectation(description: "quit")
        let queue = DispatchQueue(label: "simpilot.server")

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard let self else { return }
                let req = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let target = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let comps = URLComponents(string: target)
                let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                       uniquingKeysWith: { a, _ in a })
                let t0 = Date()
                // XCUITest API 只能在 main thread 呼叫；main thread 正在 wait(for:) 裡轉 run loop，會處理這些 block
                var body = DispatchQueue.main.sync { () -> [String: Any] in
                    self.lastRequest = Date()
                    do {
                        switch comps?.path {
                        case "/ping": return ["ok": true]
                        case "/elements": return try self.elements(query)
                        case "/tap": return try self.tap(query)
                        case "/quit": done.fulfill(); return ["ok": true]
                        default: return ["ok": false, "error": "unknown_path", "message": target]
                        }
                    } catch {
                        return ["ok": false, "error": "xcuitest_error", "message": "\(error)"]
                    }
                }
                body["serverSeconds"] = Date().timeIntervalSince(t0)
                let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
                var resp = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                                 "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n").utf8)
                resp.append(json)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
        print("SIMPILOT_READY port=\(port)")

        // idle 看門狗
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastRequest) > idle { done.fulfill() }
        }
        wait(for: [done], timeout: 24 * 3600)
        timer.invalidate()
        listener.cancel()
    }

    // MARK: - handlers

    /// 在候選 bundle 裡找前景 app。找不到回 nil。
    private func foregroundApp(_ query: [String: String]) -> (XCUIApplication, String)? {
        let bundles = (query["bundles"] ?? "").split(separator: ",").map(String.init)
        for b in bundles {
            let app = cache[b] ?? XCUIApplication(bundleIdentifier: b)
            cache[b] = app
            if app.state == .runningForeground { return (app, b) }
        }
        return nil
    }

    private func notForeground(_ query: [String: String]) -> [String: Any] {
        ["ok": false, "error": "app_not_foreground",
         "message": "none of these apps is in the foreground: \(query["bundles"] ?? "")"]
    }

    private func elements(_ query: [String: String]) throws -> [String: Any] {
        guard let (app, bundle) = foregroundApp(query) else { return notForeground(query) }
        return try Snapshot.elementsJSON(app, bundle: bundle)
    }

    private func tap(_ query: [String: String]) throws -> [String: Any] {
        guard let (app, bundle) = foregroundApp(query) else { return notForeground(query) }
        guard let text = query["label"], !text.isEmpty else {
            return ["ok": false, "error": "missing_label"]
        }
        let before = try Snapshot.signature(app)
        let pred = NSPredicate(format: "label CONTAINS %@", text)
        // button 優先（避免點到同名的 staticText 或外層容器）；只點 hittable 的，略過收起來的側邊選單這類畫面外元素
        let candidates = app.buttons.matching(pred).allElementsBoundByIndex.prefix(20)
            + app.descendants(matching: .any).matching(pred).allElementsBoundByIndex.prefix(20)
        guard !candidates.isEmpty else { return ["ok": false, "error": "not_found", "label": text] }
        guard let target = candidates.first(where: { $0.isHittable }) else {
            return ["ok": false, "error": "not_hittable", "label": text,
                    "message": "\(candidates.count) element(s) match but none is hittable"]
        }
        let tapped: [String: Any] = ["label": target.label,
                                     "role": Snapshot.role(target.elementType) ?? "application",
                                     "frame": Snapshot.frame(target.frame)]
        target.tap()
        Thread.sleep(forTimeInterval: 0.8)  // 等轉場動畫
        let after = try Snapshot.signature(app)
        return ["ok": true, "data": [
            "tapped": tapped, "bundleId": bundle,
            "screen_changed": before.hash != after.hash,
            "appeared": Array(after.labels.subtracting(before.labels).sorted().prefix(30)),
            "disappeared": Array(before.labels.subtracting(after.labels).sorted().prefix(30)),
            "moved": Array(before.moved(to: after).prefix(30)),
            "value_changed": Array(before.valueChanged(to: after).prefix(30)),
        ] as [String: Any]]
    }
}
