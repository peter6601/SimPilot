import AppKit
import SimPilotCore

/// 選單列 app：持有 daemon（Unix socket），顯示 runner 狀態，可手動關 runner、調整閒置時間。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var daemon: Daemon!
    private let menu = NSMenu()
    private let idleChoices: [TimeInterval] = [60, 180, 600, 1800]
    private let idleKey = "idleSeconds"

    func applicationDidFinishLaunching(_ note: Notification) {
        let idle = UserDefaults.standard.double(forKey: idleKey)
        daemon = Daemon(idleSeconds: idle > 0 ? idle : 180)
        do { try daemon.start() } catch {
            let alert = NSAlert()
            alert.messageText = "SimPilot 無法啟動"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        daemon.runners.onChange = { [weak self] in DispatchQueue.main.async { self?.refreshIcon() } }
        refreshIcon()
    }

    func applicationWillTerminate(_ note: Notification) {
        daemon?.shutdown()
    }

    /// 有 runner 在跑時用實心圖示，提醒 xcodebuild 正被佔用
    private func refreshIcon() {
        let running = !daemon.runners.status().isEmpty
        let img = NSImage(systemSymbolName: running ? "scope" : "circle.dashed",
                          accessibilityDescription: running ? "SimPilot runner 執行中" : "SimPilot 閒置")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let runners = daemon.runners.status()
        if runners.isEmpty {
            menu.addItem(disabled("沒有 runner 在跑（xcodebuild 未佔用）"))
        }
        for r in runners {
            let idleFor = Int(Date().timeIntervalSince(r.lastUsed))
            let state = r.ready ? "就緒，閒置 \(idleFor) 秒" : "啟動中…"
            menu.addItem(disabled("\(r.udid.prefix(8))… · \(state) · \(r.requests) 次請求"))
        }
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "關掉所有 runner", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = !runners.isEmpty
        menu.addItem(stop)

        let idleMenu = NSMenu()
        for s in idleChoices {
            let i = NSMenuItem(title: s >= 60 ? "\(Int(s / 60)) 分鐘" : "\(Int(s)) 秒",
                               action: #selector(setIdle(_:)), keyEquivalent: "")
            i.target = self
            i.tag = Int(s)
            i.state = daemon.runners.idleSeconds == s ? .on : .off
            idleMenu.addItem(i)
        }
        let idleItem = NSMenuItem(title: "閒置多久後關掉 runner", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        menu.addItem(idleItem)

        menu.addItem(.separator())
        menu.addItem(disabled("socket：\(Paths.socketPath)"))
        let quit = NSMenuItem(title: "結束 SimPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func stopAll() {
        DispatchQueue.global().async { [daemon] in daemon?.runners.stop() }
    }

    @objc private func setIdle(_ sender: NSMenuItem) {
        daemon.runners.idleSeconds = TimeInterval(sender.tag)
        UserDefaults.standard.set(Double(sender.tag), forKey: idleKey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 只出現在選單列，不出現在 Dock
app.run()
