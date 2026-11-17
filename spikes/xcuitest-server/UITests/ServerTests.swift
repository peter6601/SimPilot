import XCTest
import Network

/// 路線 3：常駐在模擬器裡的 XCUITest HTTP server（類似 WebDriverAgent 的做法）。
/// 起一次 xcodebuild，之後用 curl 查：
///   GET /elements         → elements JSON
///   GET /tap?label=文字    → 點擊結果
///   GET /quit             → 結束
/// port 用 SERVER_PORT（預設 8765）；模擬器跟 host 共用網路，127.0.0.1 直接連得到。
final class ServerTests: XCTestCase {
    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let port = NWEndpoint.Port(rawValue: UInt16(env["SERVER_PORT"] ?? "8765") ?? 8765)!
        let bundle = env["ELEMENTS_BUNDLE"] ?? "com.example.demo"
        let app = XCUIApplication(bundleIdentifier: bundle)   // 不 launch()
        let listener = try NWListener(using: .tcp, on: port)
        let done = expectation(description: "quit")
        let queue = DispatchQueue(label: "server")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let req = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let comps = URLComponents(string: path)
                var body: [String: Any]
                // XCUITest API 要在 main thread 呼叫
                let t0 = Date()
                body = DispatchQueue.main.sync { () -> [String: Any] in
                    do {
                        switch comps?.path {
                        case "/elements":
                            return try ElementsTests.snapshotJSON(app)
                        case "/tap":
                            let label = comps?.queryItems?.first { $0.name == "label" }?.value ?? ""
                            return try Self.tap(app, label)
                        case "/quit":
                            done.fulfill(); return ["ok": true]
                        default:
                            return ["ok": false, "error": "unknown path \(path)"]
                        }
                    } catch { return ["ok": false, "error": "\(error)"] }
                }
                body["serverSeconds"] = Date().timeIntervalSince(t0)
                let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
                var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                resp.append(json)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
        print("SIMPILOT_SERVER listening on \(port)")
        wait(for: [done], timeout: 3600)   // 最長常駐 1 小時
        listener.cancel()
    }

    static func tap(_ app: XCUIApplication, _ text: String) throws -> [String: Any] {
        guard app.state == .runningForeground else { return ["ok": false, "error": "app_not_foreground"] }
        let before = try ElementsTests.signature(app)
        let pred = NSPredicate(format: "label CONTAINS %@", text)
        var target = app.buttons.matching(pred).firstMatch
        if !target.exists { target = app.descendants(matching: .any).matching(pred).firstMatch }
        guard target.exists else { return ["ok": false, "error": "not_found"] }
        let label = target.label, frame = ElementsTests.frame(target.frame)
        target.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let after = try ElementsTests.signature(app)
        return ["ok": true, "tapped": ["label": label, "frame": frame],
                "screen_changed": before.hash != after.hash,
                "appeared": Array(after.labels.subtracting(before.labels).sorted().prefix(30)),
                "disappeared": Array(before.labels.subtracting(after.labels).sorted().prefix(30))]
    }
}
