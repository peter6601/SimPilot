import Foundation

/// 檔案位置與可覆寫的設定。個人工具，repo 位置直接從原始碼路徑推。
public enum Paths {
    /// repo 根目錄（Sources/SimPilotCore/Paths.swift 往上三層）
    public static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    public static var supportDir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SimPilot")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static var logsDir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SimPilot")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static var socketPath: String {
        ProcessInfo.processInfo.environment["SIMPILOT_SOCKET"] ?? supportDir.appendingPathComponent("simpilot.sock").path
    }

    public static var runnerProjectDir: URL { repoRoot.appendingPathComponent("Runner") }
    public static var runnerDerivedData: URL { supportDir.appendingPathComponent("RunnerDerivedData") }

    /// build-for-testing 產出的 .xctestrun；還沒 build 時是 nil
    public static var xctestrun: URL? {
        let products = runnerDerivedData.appendingPathComponent("Build/Products")
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }.last
    }

    /// 跑 xcodebuild 的方式。預設走 duo-verify 的 safe-xcodebuild.sh（別人在跑就 exit 1，不搶模擬器）。
    /// 回傳 (執行檔, 前置參數)；SIMPILOT_XCODEBUILD 可指定其他包裝腳本。
    public static var xcodebuild: (URL, [String]) {
        if let custom = ProcessInfo.processInfo.environment["SIMPILOT_XCODEBUILD"] {
            return (URL(fileURLWithPath: custom), [])
        }
        let safe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/duo-verify/scripts/safe-xcodebuild.sh")
        if FileManager.default.isExecutableFile(atPath: safe.path) { return (safe, []) }
        return (URL(fileURLWithPath: "/usr/bin/xcrun"), ["xcodebuild"])
    }

    /// 選單列 app 的位置（CLI 找不到 daemon 時用它來開）
    public static var appBundle: URL? {
        let candidates = [repoRoot.appendingPathComponent("build/SimPilot.app"),
                          URL(fileURLWithPath: "/Applications/SimPilot.app")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
