import XCTest

/// 附掛到已經在跑的 app（不呼叫 launch()），輸出 elements JSON，或依 label 點擊。
/// 參數用環境變數傳（xcodebuild 端加 TEST_RUNNER_ 前綴）：
///   ELEMENTS_BUNDLE  目標 app bundle id
///   ELEMENTS_OUT     輸出 JSON 路徑（模擬器跟 host 共用檔案系統，可直接寫 host 路徑）
///   ELEMENTS_LABEL   tap 用：label 包含這段文字的第一個元素
final class ElementsTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func attach() throws -> XCUIApplication {
        let bundle = env["ELEMENTS_BUNDLE"] ?? "com.example.demo"
        let app = XCUIApplication(bundleIdentifier: bundle)
        // 刻意不呼叫 launch()／activate()：launch() 會終止並重啟 app。
        guard app.state == .runningForeground else {
            throw NSError(domain: "elements", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "app not in foreground (state=\(app.state.rawValue))"])
        }
        return app
    }

    // MARK: dump

    func testDump() throws {
        let t0 = Date()
        let app = try attach()
        let out = env["ELEMENTS_OUT"] ?? "/tmp/elements.json"
        let json = try Self.snapshotJSON(app)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: out))
        print("ELEMENTS_DUMP ok out=\(out) seconds=\(Date().timeIntervalSince(t0))")
    }

    // MARK: tap

    func testTap() throws {
        let t0 = Date()
        let app = try attach()
        guard let text = env["ELEMENTS_LABEL"], !text.isEmpty else { throw NSError(domain: "elements", code: 2) }
        let before = try Self.signature(app)

        // 先找 button 類（避免點到同名的 staticText 或外層 group），找不到再找任何元素
        let pred = NSPredicate(format: "label CONTAINS %@", text)
        var target = app.buttons.matching(pred).firstMatch
        if !target.exists { target = app.descendants(matching: .any).matching(pred).firstMatch }
        guard target.exists else {
            Self.writeResult(["ok": false, "error": "not_found", "label": text]); return
        }
        let tapped = ["label": target.label, "role": Self.role(target.elementType) ?? "application",
                      "frame": Self.frame(target.frame)] as [String: Any]
        target.tap()
        Thread.sleep(forTimeInterval: 0.8)  // 等動畫
        let after = try Self.signature(app)
        let appeared = after.labels.subtracting(before.labels).sorted()
        let disappeared = before.labels.subtracting(after.labels).sorted()
        Self.writeResult(["ok": true, "tapped": tapped,
                          "screen_changed": before.hash != after.hash,
                          "appeared": Array(appeared.prefix(30)), "disappeared": Array(disappeared.prefix(30)),
                          "seconds": Date().timeIntervalSince(t0)])
    }

    private static func writeResult(_ obj: [String: Any]) {
        let out = ProcessInfo.processInfo.environment["ELEMENTS_OUT"] ?? "/tmp/elements_tap.json"
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
            print("ELEMENTS_TAP " + (String(data: data, encoding: .utf8) ?? ""))
        }
    }

    // MARK: snapshot → JSON

    static func snapshotJSON(_ app: XCUIApplication) throws -> [String: Any] {
        let root = try app.snapshot()
        // app 根節點的 frame 在橫向時仍回直向尺寸，canvas 改用第一個 window 的 frame（跟元素座標同一個座標系）
        let windows = root.children.filter { $0.elementType == .window }
        let canvas = (windows.first?.frame ?? root.frame).size
        var elements: [[String: Any]] = []
        var nextID = 1

        func walk(_ s: XCUIElementSnapshot, parent: Int?) {
            var myID = parent
            if let role = role(s.elementType), shouldEmit(s, role: role) {
                let label = s.label
                var e: [String: Any] = [
                    "id": nextID, "role": role, "label": label,
                    "frame": frame(s.frame),
                    // 有 identifier 是 role|label||id，沒有是 role|label|
                    "stableKey": s.identifier.isEmpty ? "\(role)|\(label)|" : "\(role)|\(label)||\(s.identifier)",
                    "state": s.isEnabled ? 1 : 0, "traits": [] as [String],
                ]
                if !s.identifier.isEmpty { e["identifier"] = s.identifier }
                if let p = parent { e["parentId"] = p }
                if let v = s.value as? String, !v.isEmpty { e["value"] = v }
                else if let v = s.value as? NSNumber { e["value"] = v.stringValue }
                if s.isSelected { e["selected"] = true }
                elements.append(e)
                myID = nextID
                nextID += 1
            }
            for c in s.children { walk(c, parent: myID) }
        }
        for c in root.children { walk(c, parent: nil) }

        return ["ok": true, "data": [
            "canvasSize": [canvas.width, canvas.height],
            "elements": elements,
            "deviceOrientation": XCUIDevice.shared.orientation.rawValue,
            "source": "elements-tool/XCUITest",
            "debug": ["appFrame": frame(root.frame), "windowFrames": windows.map { frame($0.frame) }],
        ] as [String: Any]]
    }

    /// 沒 label、沒 identifier 的容器不輸出，但子元素照走。
    static func shouldEmit(_ s: XCUIElementSnapshot, role: String) -> Bool {
        if s.frame.isEmpty { return false }
        let containers: Set<String> = ["group", "window"]
        if containers.contains(role) && s.label.isEmpty { return false }
        if role == "window" { return false }
        return true
    }

    static func frame(_ r: CGRect) -> [[Double]] {
        [[Double(r.origin.x), Double(r.origin.y)], [Double(r.size.width), Double(r.size.height)]]
    }

    /// XCUIElement.ElementType → role 字串（macOS AX 風格）
    static func role(_ t: XCUIElement.ElementType) -> String? {
        switch t {
        case .button: return "button"
        case .staticText: return "staticText"
        case .image, .icon: return "image"
        case .slider, .scrollBar: return "slider"
        case .switch, .toggle, .checkBox: return "checkBox"
        case .radioButton: return "radioButton"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .searchField: return "searchField"
        case .textView: return "textView"
        case .link: return "link"
        case .segmentedControl: return "segmentedControl"
        case .tab: return "radioButton"
        case .cell: return "cell"
        case .other, .toolbar, .tabBar, .navigationBar, .group, .scrollView, .table, .collectionView,
             .sheet, .alert, .layoutArea, .layoutItem:
            return "group"
        case .window: return "window"
        case .application: return nil
        case .progressIndicator, .activityIndicator: return "progressIndicator"
        case .menuButton: return "menuButton"
        case .popUpButton: return "popUpButton"
        case .pageIndicator: return "pageIndicator"
        case .picker, .pickerWheel: return "picker"
        case .stepper, .incrementArrow, .decrementArrow: return "incrementor"
        default: return "group"
        }
    }

    // MARK: 畫面指紋（tap 前後比對）

    struct Signature { let hash: Int; let labels: Set<String> }

    static func signature(_ app: XCUIApplication) throws -> Signature {
        let root = try app.snapshot()
        var hasher = Hasher()
        var labels = Set<String>()
        func walk(_ s: XCUIElementSnapshot) {
            let r = s.frame.intersection(root.frame)
            if !r.isNull && !r.isEmpty && !s.label.isEmpty {
                labels.insert(s.label)
                hasher.combine(s.label)
                hasher.combine(Int(s.frame.minX)); hasher.combine(Int(s.frame.minY))
                hasher.combine("\(String(describing: s.value))")
            }
            s.children.forEach(walk)
        }
        walk(root)
        return Signature(hash: hasher.finalize(), labels: labels)
    }
}
