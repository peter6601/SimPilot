import XCTest

/// 把 XCUITest 的元素樹轉成 `elements` 的 JSON，以及 tap 前後比對用的畫面指紋。
enum Snapshot {
    /// 回傳 `{"ok": true, "data": {"canvasSize": [w, h], "elements": [...]}}`。
    static func elementsJSON(_ app: XCUIApplication, bundle: String) throws -> [String: Any] {
        let root = try app.snapshot()
        let canvas = canvasFrame(root).size
        var elements: [[String: Any]] = []
        var nextID = 1

        func walk(_ s: XCUIElementSnapshot, parent: Int?) {
            var myID = parent
            if let role = role(s.elementType), shouldEmit(s, role: role) {
                var e: [String: Any] = [
                    "id": nextID, "role": role, "label": s.label,
                    "frame": frame(s.frame),
                    "stableKey": stableKey(role: role, label: s.label, identifier: s.identifier),
                    "state": s.isEnabled ? 1 : 0, "traits": [String](),
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
            "bundleId": bundle,
            "source": "simpilot",
        ] as [String: Any]]
    }

    /// app 根節點的 frame 在橫向時仍是直向尺寸；window 的 frame 跟元素座標在同一個座標系。
    static func canvasFrame(_ root: XCUIElementSnapshot) -> CGRect {
        root.children.first { $0.elementType == .window }?.frame ?? root.frame
    }

    /// 格式：有 identifier 是 `role|label||identifier`，沒有是 `role|label|`。
    static func stableKey(role: String, label: String, identifier: String) -> String {
        identifier.isEmpty ? "\(role)|\(label)|" : "\(role)|\(label)||\(identifier)"
    }

    /// 沒 label 的容器和 window 不輸出，子元素照走。
    static func shouldEmit(_ s: XCUIElementSnapshot, role: String) -> Bool {
        if s.frame.isEmpty || role == "window" { return false }
        if role == "group" && s.label.isEmpty { return false }
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
        case .radioButton, .tab: return "radioButton"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .searchField: return "searchField"
        case .textView: return "textView"
        case .link: return "link"
        case .segmentedControl: return "segmentedControl"
        case .cell: return "cell"
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

    struct Signature { let hash: Int; let labels: Set<String> }

    /// 畫面上看得到、有 label 的元素的 label＋位置＋value。
    static func signature(_ app: XCUIApplication) throws -> Signature {
        let root = try app.snapshot()
        let bounds = canvasFrame(root)
        var hasher = Hasher()
        var labels = Set<String>()
        func walk(_ s: XCUIElementSnapshot) {
            let r = s.frame.intersection(bounds)
            if !r.isNull && !r.isEmpty && !s.label.isEmpty {
                labels.insert(s.label)
                hasher.combine(s.label)
                hasher.combine(Int(s.frame.minX)); hasher.combine(Int(s.frame.minY))
                hasher.combine(String(describing: s.value))
            }
            s.children.forEach(walk)
        }
        walk(root)
        return Signature(hash: hasher.finalize(), labels: labels)
    }
}
