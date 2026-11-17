// 路線 1：用 macOS Accessibility API 讀 Simulator.app 視窗裡橋接過來的 iOS 元素。
import AppKit
import ApplicationServices
print("AXIsProcessTrusted =", AXIsProcessTrusted())
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
guard let sim = apps.first else { print("Simulator.app 沒在跑 → 這條路沒有可讀的視窗"); exit(3) }
let ax = AXUIElementCreateApplication(sim.processIdentifier)
var t0 = Date(); var count = 0; var sample: [String] = []
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func walk(_ e: AXUIElement, _ d: Int) {
    count += 1
    if sample.count < 40, let l = attr(e, kAXDescriptionAttribute) as? String ?? attr(e, kAXTitleAttribute) as? String, !l.isEmpty {
        var p = CGPoint.zero; var s = CGSize.zero
        if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        sample.append("\(String(repeating: " ", count: d))\(attr(e, kAXRoleAttribute) ?? "" as AnyObject) '\(l)' \(p) \(s)")
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where d < 40 { walk(c, d + 1) }
}
walk(ax, 0)
print("nodes=\(count) seconds=\(Date().timeIntervalSince(t0))"); sample.forEach { print($0) }
